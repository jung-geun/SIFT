#!/usr/bin/env python3
"""Compare source DecisionModel with the four-slot Core ML export on EN/translated KO and scheduling.

Run: USE_TF=0 /tmp/sift-laya-eval/bin/python scripts/laya_export_parity.py \
  --artifact /tmp/sift-laya-export-4choice/laya_english_4choice.mlpackage \
  --translated /tmp/sift-laya-english-evaluation.json
Two-option questions fill slots 0 and 1; slots 2 and 3 are inactive.
"""
import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from huggingface_hub import snapshot_download
from laya import Agent
from evaluate_laya_priority import FIXTURES, questions
from laya_export import ASSETS, MODEL_ID, REVISION, OPTIONS, SCHEDULE_QUESTION, SCHEDULE_STATE, prepare_batch, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--translated", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    artifact = args.artifact.expanduser().resolve()
    output = args.output or artifact.parent / "parity_49.json"
    source_report = json.loads(args.translated.read_text(encoding="utf-8"))
    if (source_report["decision_model"], source_report["decision_revision"]) != (MODEL_ID, REVISION):
        raise ValueError("Translated report decision checkpoint does not match export")
    translation = source_report["translated_states"]
    rows = json.loads(FIXTURES.read_text(encoding="utf-8"))["cases"]
    english = [row for row in rows if row["locale"] == "en"]
    korean = [row for row in rows if row["locale"] == "ko"]
    if len(english) != 24 or len(korean) != 24 or set(translation) != {row["id"] for row in korean}:
        raise ValueError("Expected exactly 24 original EN and 24 translated KO states")
    states = [(row["id"], row["state"]) for row in english]
    states += [(row["id"], translation[row["id"]]) for row in korean]
    states.append(("schedule-4", SCHEDULE_STATE))
    snapshot = snapshot_download(MODEL_ID, revision=REVISION, allow_patterns=list(ASSETS), local_files_only=True)
    agent = Agent(snapshot, device="cpu")
    agent.model.eval()
    torch.backends.mha.set_fastpath_enabled(False)
    priority_question = questions("en")
    native = ct.models.MLModel(str(artifact), compute_units=ct.ComputeUnit.CPU_AND_NE)
    names = ("input_ids", "attention_mask", "marker_pos", "marker_mask", "qtype")
    compared = []
    vectors = []
    original_width_checks = []
    for case_id, state in states:
        item, batch, length = prepare_batch(agent, state,
                                           SCHEDULE_QUESTION if case_id == "schedule-4" else priority_question)
        vectors.append({"id": case_id, "state": state,
                        "question": SCHEDULE_QUESTION if case_id == "schedule-4" else priority_question,
                        "unpadded_length": length,
                        **{name: (batch[name] if name == "qtype" else batch[name][0]).int().tolist()
                           for name in names}})
        with torch.inference_mode():
            source = agent.model(*(batch[name] for name in names))[0][0].detach().numpy()
        if case_id in (english[0]["id"], korean[0]["id"]):
            _, narrow, _ = prepare_batch(agent, state, priority_question, max_options=2)
            with torch.inference_mode():
                narrow_logits = agent.model(*(narrow[name] for name in names))[0][0].detach().numpy()
            original_width_checks.append({"id": case_id, "two_slot_source": narrow_logits.tolist(),
                                          "four_slot_active_source": source[:2].tolist(),
                                          "max_abs_error": float(np.max(np.abs(narrow_logits-source[:2])))})
        predicted = native.predict({name: batch[name].numpy().astype(np.int32) for name in names})
        coreml = np.asarray(predicted["logits"])[0]
        active = len(item["markers"])
        active_error = float(np.max(np.abs(source[:active]-coreml[:active])))
        inactive_error = float(np.max(np.abs(source[active:]-coreml[active:]))) if active < OPTIONS else 0.0
        winner = int(np.argmax(source[:active]))
        other = [i for i in range(active) if i != winner]
        source_margin = float(source[winner] - max(source[i] for i in other))
        coreml_margin = float(coreml[winner] - max(coreml[i] for i in other))
        compared.append({"id": case_id, "state": state,
                         "question": SCHEDULE_QUESTION if case_id == "schedule-4" else priority_question,
                         "unpadded_length": length, "active_options": active,
                         "marker_pos": batch["marker_pos"][0].tolist(),
                         "marker_mask": batch["marker_mask"][0].int().tolist(),
                         "source": source.tolist(), "coreml": coreml.tolist(),
                         "source_winner_margin": source_margin, "coreml_winner_margin": coreml_margin,
                         "decision_numerically_ambiguous": source_margin <= 2 * active_error,
                         "max_active_abs_error": active_error, "max_inactive_abs_error": inactive_error,
                         "argmax_agrees": bool(np.argmax(source) == np.argmax(coreml))})
    report = {"model": MODEL_ID, "revision": REVISION,
              "artifact": str(artifact),
              "artifact_manifest": digest(artifact / "Manifest.json"),
              "source_translations": {"id": source_report["translation_model"],
                                      "revision": source_report["translation_revision"],
                                      "evaluation_file_sha256": digest(args.translated)["sha256"]},
              "compute_units_requested": "CPU_AND_NE (request, not proof of ANE placement)",
              "count": len(compared), "argmax_agreement": sum(c["argmax_agrees"] for c in compared),
              "disagreements": [c["id"] for c in compared if not c["argmax_agrees"]],
              "robust_disagreements": [c["id"] for c in compared
                                       if not c["argmax_agrees"] and not c["decision_numerically_ambiguous"]],
              "max_active_abs_error": max(c["max_active_abs_error"] for c in compared),
              "max_inactive_abs_error": max(c["max_inactive_abs_error"] for c in compared),
              "masking": "Inactive marker_pos=0 is in bounds; marker_mask=0 forces the corresponding raw logit to -10000. Only active logits participate in argmax and softmax.",
              "vectors": "parity_inputs.json contains exact 512-token and four-marker inputs for every case",
              "original_width_checks": original_width_checks, "cases": compared}
    vectors_path = output.parent / "parity_inputs.json"
    vectors_path.write_text(json.dumps({"model": MODEL_ID, "revision": REVISION, "cases": vectors}, indent=2) + "\n", encoding="utf-8")
    report["vector_file"] = {"path": str(vectors_path), **digest(vectors_path)}
    if any(check["max_abs_error"] != 0 for check in original_width_checks):
        raise ValueError("Padding inactive marker slots changed original two-option source logits")
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("count", "argmax_agreement", "disagreements",
                                                    "max_active_abs_error", "max_inactive_abs_error")}, indent=2))
    print(f"Report: {output}")
    exemplars = {"en-01", "ko-01", "schedule-4"}
    if ({c["id"] for c in compared if c["id"] in exemplars} != exemplars
            or not all(c["argmax_agrees"] for c in compared if c["id"] in exemplars)
            or report["robust_disagreements"] or report["max_active_abs_error"] > 0.5
            or report["max_inactive_abs_error"] != 0):
        raise SystemExit("Parity gate failed: exemplar/robust choice disagreement, active logit error > 0.5, or inactive logit mismatch")


if __name__ == "__main__":
    main()
