#!/usr/bin/env python3
"""Offline evaluation of the exact deployed e8 L256 Core ML graph.

Run with --model-directory pointing at already-installed pinned assets; no downloads.
The legacy 48 balanced EN/KO labels grade only the exact legacy choice question.
Urgency score evaluation uses those labels ONLY as a binary proxy, never graded
0..3 ground truth. All thresholds/bins are fixed; no calibration or holdout tuning.
--predictions replays raw outputs for deterministic metrics, not model verification.
"""

import argparse
import json
import math
from collections import Counter
from pathlib import Path

from generate_laya_multilingual_vectors import (
    MODEL_FOLDER, MODEL_ID, MODEL_REVISION, SOURCE, TOKENIZER_SHA256, URGENCY,
    digest, load_tokenizer, make_sequence, question_labels,
)

FIXTURES = Path(__file__).with_name("laya_priority_fixtures.json")
MIN_ACCURACY = 0.80
MIN_CLASS_RECALL = 0.70
SCORE_THRESHOLD = 1.5
ECE_BINS = 10
NLL_FLOOR = 1e-15
PINNED_FILES = {
    "config.json": (1811, "177d55ccbc774b14d893086bf2f07a53f720fe4d5d4e6798e96624d6b38a15af"),
    "tokenizer.json": (34363188, TOKENIZER_SHA256),
    f"{MODEL_FOLDER}/model.mil": (384859, "e0a127660b301a2e90a9a844ade624ef08c2e8e3d6bdf469cd2927344664e18a"),
    f"{MODEL_FOLDER}/coremldata.bin": (1115, "14b7b96379ca462ae78fa750f365ba07bb6fb7c252069e8edf437265d7f679ba"),
    f"{MODEL_FOLDER}/analytics/coremldata.bin": (243, "df3b97214eb80318c4afaae09da42a11739b1471d499e29611c5bfe2c29de862"),
    f"{MODEL_FOLDER}/weights/weight.bin": (448323072, "1cf24b8e0a545a1ee18a881ae1d9ff175eefc144d9da2e4674d2bd219be15a50"),
}


def questions(locale, reverse=False):
    """Exact legacy prompt; retained for the English research/export callers."""
    if locale == "ko":
        prompt = "이 할 일을 다른 선택적 작업보다 먼저 해야 합니까? 상황과 지연 시 결과를 고려하세요."
        options = {
            "now": "먼저 처리: 즉각적인 피해, 임박한 기한, 또는 기다리는 사람의 일이 막힘",
            "later": "나중에 처리 가능: 긴급한 피해나 의존 관계가 없는 선택적 작업",
        }
    else:
        prompt = "Should this task be done before optional work? Consider the situation and consequences of delay."
        options = {
            "now": "Act first: immediate harm, imminent deadline, or someone is blocked waiting",
            "later": "Can defer: optional work with no urgent harm or dependent person",
        }
    if reverse:
        options = dict(reversed(list(options.items())))
    return {"priority": {"type": "choice", "instructions": prompt, "criteria": options}}


def legacy_question(locale, reverse=False):
    spec = questions(locale, reverse)["priority"]
    return {"name": "priority", "version": 1, "type": "choice", "instructions": spec["instructions"],
            "options": [{"id": key, "description": value} for key, value in spec["criteria"].items()]}


def validate(cases):
    counts = Counter((row["locale"], row["label"]) for row in cases)
    if len(cases) != 48 or len({row["id"] for row in cases}) != 48:
        raise ValueError("expected exactly 48 unique fixture IDs")
    if any(counts[locale, label] != 12 for locale in ("en", "ko") for label in ("now", "later")):
        raise ValueError(f"expected 12 per language/label, got {dict(counts)}")


def summarize(predictions):
    """Legacy accuracy API also used by evaluate_laya_english.py."""
    metrics = {}
    for locale in ("en", "ko"):
        subset = [row for row in predictions if row["locale"] == locale]
        correct = sum(row["actual"] == row["expected"] for row in subset)
        recall = {label: sum(row["actual"] == label for row in subset if row["expected"] == label) /
                  sum(row["expected"] == label for row in subset) for label in ("now", "later")}
        metrics[locale] = {"correct": correct, "total": len(subset), "accuracy": correct / len(subset), "recall": recall}
    return metrics


def finite_vector(value, count, name):
    if not isinstance(value, (list, tuple)) or len(value) != count:
        raise ValueError(f"{name}: expected {count} values")
    if any(type(item) not in (int, float) or not math.isfinite(item) for item in value):
        raise ValueError(f"{name}: nonfinite or nonnumeric value")
    return [float(item) for item in value]


def distribution(value, count, name):
    result = finite_vector(value, count, name)
    if any(not 0 <= item <= 1 for item in result) or abs(sum(result) - 1) > 0.01:
        raise ValueError(f"{name}: invalid probability distribution")
    return result


def normalize_prediction(raw, case, question):
    """Compute answer semantics from raw logits, never trust derived input decisions."""
    labels = question_labels(question)
    logits = finite_vector(raw["logits"], len(labels), "logits")
    native_probabilities = distribution(raw["raw_probabilities"], len(labels), "raw_probabilities")
    action = distribution(raw["action_probabilities"], 2, "action_probabilities")
    if type(raw["state_was_truncated"]) is not bool:
        raise ValueError("state_was_truncated must be boolean")
    if type(raw["token_count"]) is not int or not 1 <= raw["token_count"] <= 256:
        raise ValueError("invalid token_count")
    peak = max(logits)
    exp = [math.exp(value - peak) for value in logits]
    total = sum(exp)
    probabilities = [value / total for value in exp]
    winner = max(range(len(probabilities)), key=probabilities.__getitem__)
    ordered = sorted(probabilities, reverse=True)
    decisive = not raw["state_was_truncated"] and action[0] >= 0.5 and ordered[0] - ordered[1] >= 0.2
    expected_score = sum(index * value for index, value in enumerate(probabilities)) if question["type"] == "score" else None
    actual = ("now" if expected_score >= SCORE_THRESHOLD else "later") if expected_score is not None else labels[winner]
    # This score-tail mass is a binary surrogate, not a calibrated urgency probability.
    p_now = sum(probabilities[2:]) if expected_score is not None else probabilities[labels.index("now")]
    return {"id": case["id"], "locale": case["locale"], "expected": case["label"], "question": question,
            "logits": logits, "raw_probabilities": native_probabilities, "probabilities": probabilities,
            "action_probabilities": action, "state_was_truncated": raw["state_was_truncated"],
            "token_count": raw["token_count"], "selected_id": labels[winner], "expected_score": expected_score,
            "actual": actual, "correct": actual == case["label"], "p_now": p_now, "is_decisive": decisive}


class CoreMLRuntime:
    def __init__(self, directory):
        import coremltools as ct
        import numpy as np
        self.np = np
        self.assets = {}
        for name, (size, sha) in PINNED_FILES.items():
            path = directory / name
            if not path.is_file() or path.stat().st_size != size or digest(path) != sha:
                raise ValueError(f"missing or mismatched pinned asset: {path}")
            self.assets[name] = {"bytes": size, "sha256": sha}
        self.tokenizer = load_tokenizer(directory / "tokenizer.json")
        self.model = ct.models.CompiledMLModel(str(directory / MODEL_FOLDER), compute_units=ct.ComputeUnit.CPU_AND_NE)
        self.environment = {"coremltools": ct.__version__, "numpy": np.__version__}

    def predict(self, state, question):
        np = self.np
        packed = make_sequence(self.tokenizer, state, question)
        marker_map = np.zeros((1, 32, 256), dtype=np.float32)
        for index, position in enumerate(packed["marker_pos"]):
            marker_map[0, index, position] = 1
        question_type = np.zeros((1, 3), dtype=np.float32)
        question_type[0, packed["question_type"]] = 1
        output = self.model.predict({
            "input_ids": np.asarray([packed["input_ids"]], dtype=np.int32),
            "attention_mask": np.asarray([packed["attention_mask"]], dtype=np.int32),
            "marker_map": marker_map, "question_type": question_type,
        })
        arrays = {}
        for name, shape in (("logits", (1, 32)), ("probabilities", (1, 32)), ("action_probabilities", (1, 2))):
            value = np.asarray(output[name])
            if value.shape != shape or value.dtype != np.float32 or not np.isfinite(value).all():
                raise ValueError(f"invalid Core ML output {name}: shape/dtype/nonfinite")
            arrays[name] = value[0].tolist()
        active = packed["active_options"]
        return {"logits": arrays["logits"][:active], "raw_probabilities": arrays["probabilities"][:active],
                "action_probabilities": arrays["action_probabilities"],
                "state_was_truncated": packed["state_was_truncated"], "token_count": packed["token_count"]}


def evaluate(runtime, cases, as_of, score=False, reverse=False):
    predictions = []
    for case in cases:
        question = URGENCY if score else legacy_question(case["locale"], reverse)
        # Legacy state has no new evidence, preserving historical comparison. Score
        # framing uses the existing fixture clock, never the machine's current date.
        state = {**case["state"], "context": f"Current time: {as_of}" if score else "", "wasTruncated": False}
        raw = runtime.predict(state, question)
        predictions.append(normalize_prediction(raw, case, question))
    return predictions


def replay(rows, cases, score=False, reverse=False):
    if not isinstance(rows, list) or len(rows) != len(cases):
        raise ValueError("prediction count must match all 48 fixture cases")
    ids = [row["id"] for row in rows]
    if len(set(ids)) != len(ids) or set(ids) != {case["id"] for case in cases}:
        raise ValueError("prediction IDs missing, duplicate, or unexpected")
    by_id = {row["id"]: row for row in rows}
    predictions = []
    for case in cases:
        row = by_id[case["id"]]
        question = URGENCY if score else legacy_question(case["locale"], reverse)
        if row.get("question", question) != question:
            raise ValueError(f"question mismatch for {case['id']}")
        if row.get("locale", case["locale"]) != case["locale"] or row.get("expected", case["label"]) != case["label"]:
            raise ValueError(f"fixture metadata mismatch for {case['id']}")
        predictions.append(normalize_prediction(row, case, question))
    return predictions


def selective_metrics(rows):
    kept = [row for row in rows if row["is_decisive"]]
    held = [row for row in rows if not row["is_decisive"]]
    def group(subset):
        errors = sum(not row["correct"] for row in subset)
        return {"count": len(subset), "errors": errors, "error_rate": errors / len(subset) if subset else None}
    return {"coverage": len(kept) / len(rows), "decisive": group(kept), "held": group(held)}


def probability_metrics(rows):
    bins = []
    for index in range(ECE_BINS):
        subset = [row for row in rows if min(ECE_BINS - 1, int(row["p_now"] * ECE_BINS)) == index]
        p_mean = sum(row["p_now"] for row in subset) / len(subset) if subset else None
        now_rate = sum(row["expected"] == "now" for row in subset) / len(subset) if subset else None
        bins.append({"lower": index / ECE_BINS, "upper": (index + 1) / ECE_BINS,
                     "count": len(subset), "mean_p_now": p_mean, "observed_now_rate": now_rate})
    return {"brier": sum((row["p_now"] - int(row["expected"] == "now")) ** 2 for row in rows) / len(rows),
            "nll": -sum(math.log(max(NLL_FLOOR, row["p_now"] if row["expected"] == "now" else 1 - row["p_now"])) for row in rows) / len(rows),
            "ece": sum(item["count"] * abs(item["mean_p_now"] - item["observed_now_rate"]) for item in bins if item["count"]) / len(rows),
            "ece_bins": bins, "selective": selective_metrics(rows)}


def full_metrics(rows):
    result = summarize(rows)
    for locale in ("en", "ko"):
        result[locale].update(probability_metrics([row for row in rows if row["locale"] == locale]))
    correct = sum(row["correct"] for row in rows)
    result["all"] = {"correct": correct, "total": len(rows), "accuracy": correct / len(rows),
                     "recall": {label: sum(row["correct"] for row in rows if row["expected"] == label) /
                                sum(row["expected"] == label for row in rows) for label in ("now", "later")},
                     **probability_metrics(rows)}
    return result


def gate(metrics):
    return all(metrics[locale]["accuracy"] >= MIN_ACCURACY and
               all(value >= MIN_CLASS_RECALL for value in metrics[locale]["recall"].values()) for locale in ("en", "ko"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--model-directory", type=Path, help="Offline directory with exact pinned config/tokenizer/compiled graph")
    source.add_argument("--predictions", type=Path, help="Metrics-only JSON: model/revision, legacy_predictions, urgency_predictions, optional reverse_predictions; each row id/logits/raw_probabilities/action_probabilities/state_was_truncated/token_count")
    parser.add_argument("--output", type=Path, default=Path("/tmp/sift-laya-priority-evaluation.json"))
    args = parser.parse_args()
    fixture = json.loads(FIXTURES.read_text(encoding="utf-8"))
    cases = fixture["cases"]
    validate(cases)
    if args.predictions:
        payload = json.loads(args.predictions.read_text(encoding="utf-8"))
        if payload.get("model") != MODEL_ID or payload.get("revision") != MODEL_REVISION:
            raise ValueError("prediction file must identify exact deployed model/revision")
        legacy = replay(payload["legacy_predictions"], cases)
        urgency = replay(payload["urgency_predictions"], cases, score=True)
        reverse = replay(payload["reverse_predictions"], cases, reverse=True) if "reverse_predictions" in payload else None
        evidence = {"mode": "offline_metrics_only", "input": str(args.predictions),
                    "input_sha256": digest(args.predictions), "real_model_run": False}
    else:
        runtime = CoreMLRuntime(args.model_directory.expanduser().resolve())
        legacy = evaluate(runtime, cases, fixture["as_of"])
        urgency = evaluate(runtime, cases, fixture["as_of"], score=True)
        reverse = evaluate(runtime, cases, fixture["as_of"], reverse=True)
        evidence = {"mode": "real_coreml", "real_model_run": True, "assets": runtime.assets,
                    "environment": runtime.environment, "compute_units_requested": "CPU_AND_NE (not proof of ANE placement)"}
    legacy_metrics, urgency_metrics = full_metrics(legacy), full_metrics(urgency)
    passed = gate(legacy_metrics)
    result = {
        "schema_version": 2, "model": MODEL_ID, "revision": MODEL_REVISION, "artifact": MODEL_FOLDER, "source": SOURCE,
        "fixture": str(FIXTURES), "fixture_sha256": digest(FIXTURES), "as_of": fixture["as_of"], "evidence": evidence,
        "gate": {"accuracy_per_locale": MIN_ACCURACY, "recall_per_class": MIN_CLASS_RECALL,
                 "applies_to": "legacy choice only; urgency has no graded ground truth"},
        "probability_metrics": {"calibrated": False, "ece": "10 fixed equal-width bins of p_now vs observed binary now rate; last bin includes 1",
                                "nll_probability_floor": NLL_FLOOR,
                                "is_decisive": "not truncated AND action_probabilities[0]>=0.5 AND top-two softmax margin>=0.2"},
        "legacy": {"metrics": legacy_metrics, "passed": passed, "state_context": "empty (historical state evidence unchanged)"},
        "urgency_binary_proxy": {
            "ground_truth": "Existing now/later labels ONLY; not graded urgency levels, no graded metrics or gate",
            "decision_rule": "expectedScore >= 1.5 means now; fixed before evaluation, not tuned on these cases",
            "probability_proxy": "p_now = softmax mass at levels 2 and 3; binary surrogate, uncalibrated",
            "state_context": "Current time: " + fixture["as_of"], "metrics": urgency_metrics,
        },
        "passed": passed, "legacy_predictions": legacy, "urgency_predictions": urgency,
    }
    if reverse is not None:
        result["reverse_order_diagnostic"] = {
            "diagnostic_only": True, "cannot_rescue_gate": True, "metrics": full_metrics(reverse),
            "changed_ids": [a["id"] for a, b in zip(legacy, reverse, strict=True) if a["actual"] != b["actual"]],
        }
        result["reverse_predictions"] = reverse
    else:
        result["reverse_order_diagnostic"] = {"status": "not supplied in metrics-only input", "cannot_rescue_gate": True}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if not key.endswith("predictions")}, ensure_ascii=False, indent=2, allow_nan=False))
    print(f"Predictions: {args.output}")
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
