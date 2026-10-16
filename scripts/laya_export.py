#!/usr/bin/env python3
"""Export pinned English Laya DecisionModel to Core ML, and compare real fixture logits.

Run: USE_TF=0 /tmp/sift-laya-eval/bin/python scripts/laya_export.py \
  --output /tmp/sift-laya-export-4choice
Dependencies: scripts/laya-eval-requirements.txt plus scripts/laya_export_requirements.txt.
The static 512-token boundary matches the pinned checkpoint's max_len.
Preprocessing MUST use laya.common.build_sequence(max_len=512) before padding;
no raw token clipping. Two-option rows occupy the first two of four marker slots.
"""
import argparse
import hashlib
import json
import platform
import shutil
import traceback
from pathlib import Path

import numpy as np
import torch
from huggingface_hub import snapshot_download
from laya import Agent
from laya.common import collate_items
from evaluate_laya_priority import FIXTURES, questions

MODEL_ID = "convaiinnovations/laya"
REVISION = "55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851"
ASSETS = ("rl_agent_config.json", "model.safetensors", "encoder/config.json",
          "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json")
LENGTH = 512
OPTIONS = 4


SCHEDULE_QUESTION = {"schedule": {
    "type": "choice",
    "instructions": "When should this task be scheduled? Consider its deadline and who is waiting.",
    "criteria": {
        "today": "Do today: a deadline or a dependent person needs action now",
        "this_week": "Do this week: important but not needed today",
        "next_week": "Do next week: no near-term deadline or dependency",
        "someday": "Defer without a date: optional and no one is waiting",
    },
}}
SCHEDULE_STATE = {"title": "Send the review agenda to the team",
                  "details": "Four colleagues need the agenda before tomorrow's 9 AM meeting.",
                  "due": "Tomorrow at 9 AM"}


def prepare_batch(agent, state, question, max_options=OPTIONS):
    """Use Laya's own sequence builder and collator, then extend only inactive slots."""
    name, spec = next(iter(question.items()))
    internal = agent._to_internal(spec)
    item = agent._encode_state(state, [name], {name: internal}, max_len=LENGTH)[0]
    active = len(item["markers"])
    if not 2 <= active <= max_options:
        raise ValueError(f"Expected 2..{max_options} markers, got {item['markers']}")
    batch = collate_items([[item]], agent.tok.pad_token_id)
    length = batch["input_ids"].shape[1]
    if length > LENGTH:
        raise ValueError(f"Input length {length} exceeds static boundary {LENGTH}")
    batch["input_ids"] = torch.nn.functional.pad(batch["input_ids"], (0, LENGTH-length),
                                                    value=agent.tok.pad_token_id)
    batch["attention_mask"] = torch.nn.functional.pad(batch["attention_mask"], (0, LENGTH-length))
    batch["marker_pos"] = torch.nn.functional.pad(batch["marker_pos"], (0, max_options-active))
    batch["marker_mask"] = torch.nn.functional.pad(batch["marker_mask"], (0, max_options-active))
    return item, batch, length


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return {"bytes": path.stat().st_size, "sha256": sha.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/tmp/sift-laya-export-4choice"))
    parser.add_argument("--precision", choices=("float32", "float16"), default="float16",
                        help="float32 checks reference parity; float16 tests Neural Engine eligibility")
    args = parser.parse_args()
    out = args.output.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = {"checkpoint": {"id": MODEL_ID, "revision": REVISION},
              "environment": {"macOS": platform.mac_ver()[0], "machine": platform.machine(),
                              "torch": torch.__version__}, "stage": "checkpoint"}
    try:
        # Restrict downloads to the model inputs; the upstream repository contains other models.
        snapshot = Path(snapshot_download(MODEL_ID, revision=REVISION,
                       allow_patterns=list(ASSETS), local_files_only=True))
        report["checkpoint"]["assets"] = {asset: digest(snapshot / asset) for asset in ASSETS}
        tokenizer_assets = {}
        for name in ("tokenizer.json", "tokenizer_config.json"):
            target = out / name
            shutil.copyfile(snapshot / "tokenizer" / name, target)
            tokenizer_assets[name] = digest(target)
        report["tokenizer_assets"] = tokenizer_assets
        import coremltools as ct
        report["environment"]["coremltools"] = ct.__version__
        report["stage"] = "source"
        agent = Agent(str(snapshot), device="cpu")
        agent.model.eval()
        priority_question = questions("en")
        rows = [row for row in json.loads(FIXTURES.read_text(encoding="utf-8"))["cases"]
                if row["locale"] == "en"]
        rows.append({"id": "schedule-4", "state": SCHEDULE_STATE})
        examples = []
        batches = []
        for row in rows:
            item, batch, count = prepare_batch(agent, row["state"],
                                               SCHEDULE_QUESTION if row["id"] == "schedule-4" else priority_question)
            batches.append(batch)
            examples.append({"id": row["id"], "input_ids": batch["input_ids"][0].tolist(),
                             "attention_mask": batch["attention_mask"][0].tolist(),
                             "marker_pos": batch["marker_pos"][0].tolist(),
                             "marker_mask": batch["marker_mask"][0].int().tolist(),
                             "qtype": int(item["qtype"]), "unpadded_length": count})
        report["io"] = {"batch": 1, "sequence_length": LENGTH, "options": OPTIONS,
                        "inputs": {"input_ids": [1, LENGTH], "attention_mask": [1, LENGTH],
                                   "marker_pos": [1, OPTIONS], "marker_mask": [1, OPTIONS],
                                   "qtype": [1]},
                        "outputs": {"logits": [1, OPTIONS]},
                        "input_dtype": "int32", "output_dtype": "float32",
                        "qtype_choice": 0, "pad_id": agent.tok.pad_token_id,
                        "cls_id": agent.tok.cls_token_id, "sep_id": agent.tok.sep_token_id,
                        "mask_id": agent.tok.mask_token_id,
                        "preprocessing": "Agent._to_internal + Agent._encode_state(max_len=512) + collate_items; right-pad tokens to 512 and inactive marker slots to 4 with position 0, mask 0; raw logits before temperature; masked logits -10000"}
        (out / "fixtures.json").write_text(json.dumps(examples, indent=2) + "\n")

        class Decision(torch.nn.Module):
            def __init__(self, model):
                super().__init__()
                self.model = model

            def forward(self, input_ids, attention_mask, marker_pos, marker_mask, qtype):
                return self.model(input_ids, attention_mask, marker_pos.long(), marker_mask.bool(), qtype.long())[0]

        model = Decision(agent.model).eval()
        # PyTorch inference fastpath replaces the head with a fused aten op
        # unsupported by coremltools; keep the same unfused Transformer layer.
        torch.backends.mha.set_fastpath_enabled(False)
        names = tuple(report["io"]["inputs"])
        values = lambda batch: tuple(batch[name].to(torch.int32) for name in names)
        with torch.inference_mode():
            source = [tuple(t.detach().numpy() for t in agent.model(*(batch[name] for name in names)))
                      for batch in batches]
        selected = {"en-01", "en-06", "en-24", "schedule-4"}
        parity_vectors = [{"id": row["id"], "state": row["state"],
                           "question": SCHEDULE_QUESTION if row["id"] == "schedule-4" else priority_question,
                           **example, "logits": output[0][0].tolist()}
                          for row, example, output in zip(rows, examples, source)
                          if row["id"] in selected]
        if {row["id"] for row in parity_vectors} != selected:
            raise ValueError("Missing a requested parity fixture")
        vectors_path = out / "vectors.json"
        vectors_path.write_text(json.dumps({"model": MODEL_ID, "revision": REVISION,
                                            "tokenizer_sha256": report["tokenizer_assets"]["tokenizer.json"]["sha256"],
                                            "sequence_length": LENGTH, "cases": parity_vectors}, indent=2) + "\n")
        report["vectors"] = {"path": str(vectors_path), **digest(vectors_path)}
        report["stage"] = "trace"
        with torch.inference_mode():
            traced = torch.jit.trace(model, values(batches[-1]), check_trace=False)
            traced_results = [traced(*values(batch)).detach().numpy() for batch in batches]
        report["trace_max_abs_error"] = max(float(np.max(np.abs(reference[0]-result)))
                                            for reference, result in zip(source, traced_results))
        report["stage"] = "conversion"
        # Transformers' bidirectional mask uses q_idx.new_ones((), dtype=bool).
        # coremltools 9 has no lowering for aten::new_ones, although this particular
        # expression is a scalar True independent of q_idx. Reject other shapes.
        from coremltools.converters.mil import Builder as mb
        from coremltools.converters.mil.frontend.torch.ops import _get_inputs
        from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op

        @register_torch_op
        def new_ones(context, node):
            tensor, shape, dtype, *rest = _get_inputs(context, node)
            if (shape is None or shape.val is None or np.asarray(shape.val).size != 0
                    or dtype is None or dtype.val != 11):
                raise ValueError(f"Unexpected new_ones arguments: shape={shape}, shape_value={getattr(shape, 'val', None)}, dtype={dtype}, dtype_value={getattr(dtype, 'val', None)}")
            context.add(mb.const(val=np.array(True), name=node.name))
        # ct9's int constant-folding calls int(ndarray([value])), which NumPy
        # rejects. Preserve the scalar-tensor semantics for this case only.
        from coremltools.converters.mil.frontend.torch.torch_op_registry import _TORCH_OPS_REGISTRY
        original_int = _TORCH_OPS_REGISTRY.get_func("int")

        @register_torch_op(torch_alias=["int"], override=True)
        def _int_scalar_tensor(context, node):
            x = _get_inputs(context, node, expected=1)[0]
            if x.can_be_folded_to_const() and isinstance(x.val, np.ndarray) and x.val.size == 1:
                context.add(mb.const(val=np.int32(x.val.item()), name=node.name))
            else:
                original_int(context, node)
        # TorchScript's int64 marker indices are represented as fp32 in MIL.
        # Our marker positions are <= 511 and exactly representable: restore
        # integer indices before the Core ML gather (no numeric rounding).
        @register_torch_op(override=True)
        def gather(context, node):
            x, axis, indices, *rest = _get_inputs(context, node)
            context.add(mb.gather_along_axis(x=x, indices=mb.cast(x=indices, dtype="int32"),
                                             axis=axis, name=node.name))

        inputs = [ct.TensorType(name=name, shape=tuple(t.shape), dtype=np.int32)
                  for name, t in zip(names, values(batches[0]))]
        ml = ct.convert(traced, source="pytorch", inputs=inputs,
                        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
                        convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
                        compute_precision=(ct.precision.FLOAT16 if args.precision == "float16"
                                           else ct.precision.FLOAT32), skip_model_load=True)
        report["compute_precision"] = args.precision
        artifact = out / "laya_english_4choice.mlpackage"
        ml.save(str(artifact))
        report["stage"] = "native_prediction"
        native = ct.models.MLModel(str(artifact), compute_units=ct.ComputeUnit.CPU_AND_NE)
        comparisons = []
        for row, batch, reference, python_result in zip(rows, batches, source, traced_results):
            prediction = native.predict({name: tensor.numpy().astype(np.int32) for name, tensor in zip(names, values(batch))})
            measured = np.asarray(prediction["logits"])[0]
            logits = reference[0][0]
            trace_logits = python_result[0]
            active = int(batch["marker_mask"].sum())
            active_error = float(np.max(np.abs(logits[:active] - measured[:active])))
            masked_error = float(np.max(np.abs(logits[active:] - measured[active:]))) if active < OPTIONS else 0.0
            winner = int(np.argmax(logits[:active]))
            source_margin = float(logits[winner] - max(logits[i] for i in range(active) if i != winner))
            comparisons.append({"id": row["id"], "active_options": active,
                                "marker_pos": batch["marker_pos"][0].tolist(),
                                "marker_mask": batch["marker_mask"][0].int().tolist(),
                                "source": logits.tolist(), "python_trace": trace_logits.tolist(),
                                "coreml": measured.tolist(), "max_active_abs_error": active_error,
                                "source_winner_margin": source_margin,
                                "decision_numerically_ambiguous": source_margin <= 2 * active_error,
                                "max_masked_abs_error": masked_error,
                                "argmax_agrees": bool(np.argmax(logits) == np.argmax(measured))})
        report["comparisons"] = comparisons
        report["max_active_abs_error"] = max(row["max_active_abs_error"] for row in comparisons)
        report["max_masked_abs_error"] = max(row["max_masked_abs_error"] for row in comparisons)
        report["argmax_agreement"] = sum(row["argmax_agrees"] for row in comparisons)
        report["compute_units_requested"] = "CPU_AND_NE (request, not proof of ANE placement)"
        report["robust_disagreements"] = [row["id"] for row in comparisons
                                          if not row["argmax_agrees"] and not row["decision_numerically_ambiguous"]]
        if (report["robust_disagreements"] or report["max_active_abs_error"] > 0.5
                or report["max_masked_abs_error"] != 0
                or any(not row["argmax_agrees"] for row in comparisons if row["id"] in selected)):
            raise ValueError("Core ML missed a parity exemplar/robust decision, exceeded 0.5 active-logit error, or failed inactive masking")
        report["stage"] = "complete"
        report["artifact"] = artifact.name
        # ML packages are directories: hash each actual payload, never hash directory metadata.
        report["artifact_files"] = {str(path.relative_to(out)): digest(path)
                                   for path in sorted(artifact.rglob("*")) if path.is_file()}
    except Exception as exc:
        report["failure"] = {"type": type(exc).__name__, "message": str(exc),
                             "traceback": traceback.format_exc()}
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({key: report[key] for key in ("stage", "trace_max_abs_error", "max_active_abs_error", "failure")
                          if key in report}, indent=2))
        print(f"Report: {out / 'report.json'}")
    if report["stage"] != "complete":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
