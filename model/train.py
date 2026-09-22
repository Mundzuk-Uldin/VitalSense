"""Train the health-risk model with fastai and export it for Core ML.

    python train.py [--data ../Health_Risk_Dataset.csv] [--out artifacts]

The apps run the exported model on the device, so there is no server and no
network in the prediction path. Everything this script emits lands in
`artifacts/` and is copied into the Xcode project.
"""

from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from fastai.tabular.all import (
    Categorify,
    CategoryBlock,
    Normalize,
    RandomSplitter,
    TabularPandas,
    accuracy,
    range_of,
    tabular_learner,
)

import news2

RANDOM_SEED = 42

# Order matters enormously: Swift builds this exact vector, in this exact
# order, and nothing at runtime would catch a mismatch. `reference.json`
# exists to make a mismatch fail loudly instead.
CONTINUOUS_FEATURES = [
    "Respiratory_Rate",
    "Oxygen_Saturation",
    "O2_Scale",
    "Systolic_BP",
    "Heart_Rate",
    "Temperature",
    "On_Oxygen",
    "NEWS2_Total",
    "NEWS2_Max",
    "NEWS2_Abnormal",
]
CATEGORICAL_FEATURES = ["Consciousness"]
TARGET = "Risk_Level"

# Least to most acute, for reporting. This is *not* the model's class order,
# which fastai sorts alphabetically -- see `classes` in metadata.json.
RISK_ORDER = ["Normal", "Low", "Medium", "High"]


class ScoringModel(torch.nn.Module):
    """Wraps the fastai model so the exported Core ML graph takes *raw*
    vitals and returns probabilities.

    Normalisation lives inside the graph as buffers rather than being
    reimplemented in Swift. Ten means and ten standard deviations copied by
    hand into another language is exactly the kind of thing that silently
    drifts, and a drifted normaliser does not crash -- it just quietly makes
    the model wrong.
    """

    def __init__(self, model: torch.nn.Module, means: np.ndarray, stds: np.ndarray) -> None:
        super().__init__()
        self.model = model
        self.register_buffer("means", torch.tensor(means, dtype=torch.float32))
        self.register_buffer("stds", torch.tensor(stds, dtype=torch.float32))

    def forward(self, categorical: torch.Tensor, continuous: torch.Tensor) -> torch.Tensor:
        normalised = (continuous - self.means) / self.stds
        return torch.softmax(self.model(categorical, normalised), dim=1)


def add_news2_features(frame: pd.DataFrame) -> pd.DataFrame:
    """Hand the network the NEWS2 sub-scores alongside the raw vitals.

    The apps compute these anyway to explain a result, so they cost nothing
    at inference, and they save the network from rediscovering the clinical
    cut-points from 1,000 rows.
    """
    frame = frame.copy()
    rows = []
    for row in frame.itertuples(index=False):
        components = news2.components(
            respiratory_rate=row.Respiratory_Rate,
            oxygen_saturation=row.Oxygen_Saturation,
            o2_scale=row.O2_Scale,
            systolic_bp=row.Systolic_BP,
            heart_rate=row.Heart_Rate,
            temperature=row.Temperature,
            consciousness=row.Consciousness,
            on_oxygen=row.On_Oxygen,
        )
        scores = [c.score for c in components]
        rows.append((sum(scores), max(scores), sum(1 for s in scores if s > 0)))
    frame["NEWS2_Total"], frame["NEWS2_Max"], frame["NEWS2_Abnormal"] = zip(*rows)
    return frame


def ordinal_error(true_labels: list[str], predicted: list[str]) -> float:
    """Mean number of bands each prediction is off by.

    Accuracy treats Normal-mistaken-for-High the same as
    Low-mistaken-for-Medium. Clinically those are nothing alike.
    """
    index = {label: i for i, label in enumerate(RISK_ORDER)}
    return float(
        np.abs(
            np.array([index[v] for v in true_labels]) - np.array([index[v] for v in predicted])
        ).mean()
    )


def main() -> None:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=here.parent / "Health_Risk_Dataset.csv")
    parser.add_argument("--out", type=Path, default=here / "artifacts")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--lr", type=float, default=1e-2)
    args = parser.parse_args()

    torch.manual_seed(RANDOM_SEED)
    np.random.seed(RANDOM_SEED)

    frame = add_news2_features(pd.read_csv(args.data))
    print(f"Loaded {len(frame)} rows from {args.data}")
    print("Class balance:", frame[TARGET].value_counts().reindex(RISK_ORDER).to_dict(), "\n")

    splits = RandomSplitter(valid_pct=0.2, seed=RANDOM_SEED)(range_of(frame))
    tabular = TabularPandas(
        frame,
        procs=[Categorify, Normalize],
        cat_names=CATEGORICAL_FEATURES,
        cont_names=CONTINUOUS_FEATURES,
        y_names=TARGET,
        y_block=CategoryBlock(),
        splits=splits,
    )
    loaders = tabular.dataloaders(bs=64)

    learner = tabular_learner(loaders, layers=[64, 32], metrics=accuracy)
    learner.fit_one_cycle(args.epochs, args.lr)

    classes = list(loaders.vocab)
    # fastai reserves index 0 of every categorical column for unseen values.
    category_map = {k: int(v) for k, v in tabular.procs.categorify.classes["Consciousness"].o2i.items()}
    means = np.array([float(tabular.procs.normalize.means[c]) for c in CONTINUOUS_FEATURES])
    stds = np.array([float(tabular.procs.normalize.stds[c]) for c in CONTINUOUS_FEATURES])

    print(f"\nClasses (model order): {classes}")
    print(f"Consciousness map: {category_map}")

    # ---- evaluate on the held-out split ------------------------------------
    scorer = ScoringModel(learner.model.to("cpu").eval(), means, stds).eval()
    valid = frame.iloc[splits[1]]
    categorical, continuous = encode(valid, category_map)
    with torch.no_grad():
        probabilities = scorer(categorical, continuous).numpy()
    predicted = [classes[i] for i in probabilities.argmax(axis=1)]
    actual = valid[TARGET].tolist()

    from sklearn.metrics import classification_report, confusion_matrix, f1_score

    print()
    print(classification_report(actual, predicted, labels=RISK_ORDER, zero_division=0))
    print(f"Confusion matrix (rows actual, cols predicted; order {RISK_ORDER}):")
    print(confusion_matrix(actual, predicted, labels=RISK_ORDER))
    holdout = {
        "accuracy": float(np.mean(np.array(predicted) == np.array(actual))),
        "macro_f1": float(f1_score(actual, predicted, average="macro")),
        "mean_bands_off": ordinal_error(actual, predicted),
        "n": int(len(valid)),
    }
    print(f"\nheld-out accuracy = {holdout['accuracy']:.4f}")
    print(f"held-out macro-F1 = {holdout['macro_f1']:.4f}")
    print(f"mean bands off    = {holdout['mean_bands_off']:.4f}")

    # ---- export ------------------------------------------------------------
    args.out.mkdir(parents=True, exist_ok=True)
    export_coreml(scorer, args.out, classes, category_map)
    write_reference(scorer, frame, classes, category_map, args.out)

    metadata = {
        "framework": "fastai",
        "architecture": "tabular_learner, layers [64, 32], embedding for Consciousness",
        "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "dataset": args.data.name,
        "n_rows": int(len(frame)),
        "epochs": args.epochs,
        "continuous_features": CONTINUOUS_FEATURES,
        "categorical_features": CATEGORICAL_FEATURES,
        "classes": classes,
        "risk_order": RISK_ORDER,
        "consciousness_map": category_map,
        "normalisation": {
            "note": "Baked into the exported graph; Swift passes raw values.",
            "means": dict(zip(CONTINUOUS_FEATURES, means.round(6).tolist())),
            "stds": dict(zip(CONTINUOUS_FEATURES, stds.round(6).tolist())),
        },
        "holdout": holdout,
    }
    (args.out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"\nWrote {args.out}/")


def encode(frame: pd.DataFrame, category_map: dict[str, int]) -> tuple[torch.Tensor, torch.Tensor]:
    """Raw frame -> the two tensors the exported graph expects."""
    categorical = torch.tensor(
        [[category_map.get(str(v), 0)] for v in frame["Consciousness"]], dtype=torch.long
    )
    continuous = torch.tensor(
        frame[CONTINUOUS_FEATURES].to_numpy(dtype="float32"), dtype=torch.float32
    )
    return categorical, continuous


def export_coreml(
    scorer: ScoringModel, out: Path, classes: list[str], category_map: dict[str, int]
) -> None:
    import coremltools as ct

    example = (torch.ones(1, 1, dtype=torch.long), torch.zeros(1, len(CONTINUOUS_FEATURES)))
    with torch.no_grad():
        traced = torch.jit.trace(scorer, example)

    # The `neuralnetwork` format rather than `mlprogram`: it is all a
    # ten-input MLP needs, it runs on watchOS 6 and up, and coremltools'
    # mlprogram weight writer has no working build for this Python.
    model = ct.convert(
        traced,
        convert_to="neuralnetwork",
        inputs=[
            ct.TensorType(name="categorical", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="continuous", shape=(1, len(CONTINUOUS_FEATURES)), dtype=np.float32),
        ],
    )
    # coremltools names the output after an internal graph variable
    # ("var_66"), which would be an awful thing to reference from Swift.
    # `get_spec()` hands back a copy, so the rename has to happen on one
    # spec object that is then used to rebuild the model.
    spec = model.get_spec()
    ct.utils.rename_feature(spec, spec.description.output[0].name, "probabilities")
    model = ct.models.MLModel(spec)

    model.short_description = (
        "NEWS2-style clinical risk from vitals. Outputs probabilities over "
        f"{classes}. Normalisation is inside the graph; pass raw values."
    )
    model.input_description["categorical"] = f"Consciousness index. {category_map}"
    model.input_description["continuous"] = f"Raw vitals in order: {CONTINUOUS_FEATURES}"
    model.output_description["probabilities"] = f"Softmax over {classes}, in that order."
    path = out / "VitalRisk.mlmodel"
    model.save(str(path))
    print(f"Exported {path} ({path.stat().st_size / 1024:.0f} KB)")

    # Deploy into the shared app sources, so retraining and rebuilding the
    # apps is one command rather than two plus a copy someone forgets.
    deployed = out.parent.parent / "app" / "Shared" / "VitalRisk.mlmodel"
    if deployed.parent.is_dir():
        shutil.copy2(path, deployed)
        print(f"Deployed to {deployed.relative_to(out.parent.parent)}")


def write_reference(
    scorer: ScoringModel,
    frame: pd.DataFrame,
    classes: list[str],
    category_map: dict[str, int],
    out: Path,
) -> None:
    """Freeze a handful of PyTorch predictions so Swift can prove the Core ML
    model it loads agrees with the model that was trained.

    Without this, a wrong feature order or a stale .mlmodel in the bundle
    produces plausible-looking numbers and nobody notices.
    """
    sample = frame.sample(24, random_state=RANDOM_SEED)
    categorical, continuous = encode(sample, category_map)
    with torch.no_grad():
        probabilities = scorer(categorical, continuous).numpy()

    cases = []
    for i, row in enumerate(sample.itertuples(index=False)):
        cases.append(
            {
                "respiratory_rate": float(row.Respiratory_Rate),
                "oxygen_saturation": float(row.Oxygen_Saturation),
                "o2_scale": int(row.O2_Scale),
                "systolic_bp": float(row.Systolic_BP),
                "heart_rate": float(row.Heart_Rate),
                "temperature": float(row.Temperature),
                "on_oxygen": bool(row.On_Oxygen),
                "consciousness": str(row.Consciousness),
                "expected_label": classes[int(probabilities[i].argmax())],
                "expected_probabilities": dict(
                    zip(classes, [round(float(p), 6) for p in probabilities[i]])
                ),
                "dataset_label": str(getattr(row, TARGET)),
            }
        )
    (out / "reference.json").write_text(json.dumps({"classes": classes, "cases": cases}, indent=2) + "\n")
    agreement = np.mean([c["expected_label"] == c["dataset_label"] for c in cases])
    print(f"Wrote reference.json ({len(cases)} cases, {agreement:.0%} agree with dataset labels)")


if __name__ == "__main__":
    main()
