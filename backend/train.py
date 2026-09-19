"""Train the health-risk classifier.

    python train.py [--data ../Health_Risk_Dataset.csv] [--out artifacts]

Compares a few candidate models by stratified cross-validated macro-F1,
refits the winner on the full training split, reports held-out metrics, and
writes the fitted pipeline plus a metadata sidecar to artifacts/.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, confusion_matrix, f1_score
from sklearn.model_selection import StratifiedKFold, cross_val_score, train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from features import (
    CATEGORICAL_FEATURES,
    DERIVED_FEATURES,
    FEATURE_COLUMNS,
    NUMERIC_FEATURES,
    RISK_ORDER,
    TARGET,
    add_derived,
)

RANDOM_STATE = 42


def load_dataset(path: Path) -> tuple[pd.DataFrame, pd.Series]:
    raw = pd.read_csv(path)
    missing = {*NUMERIC_FEATURES, *CATEGORICAL_FEATURES, TARGET} - set(raw.columns)
    if missing:
        raise SystemExit(f"{path} is missing required columns: {sorted(missing)}")
    frame = add_derived(raw)
    return frame[FEATURE_COLUMNS], frame[TARGET]


def make_preprocessor(scale_numeric: bool) -> ColumnTransformer:
    numeric = NUMERIC_FEATURES + DERIVED_FEATURES
    return ColumnTransformer(
        [
            ("num", StandardScaler() if scale_numeric else "passthrough", numeric),
            (
                "cat",
                OneHotEncoder(handle_unknown="ignore", sparse_output=False),
                CATEGORICAL_FEATURES,
            ),
        ]
    )


def candidates() -> dict[str, Pipeline]:
    """Three models spanning the bias/variance range, so the choice is
    measured rather than assumed."""
    return {
        "logistic_regression": Pipeline(
            [
                ("prep", make_preprocessor(scale_numeric=True)),
                ("clf", LogisticRegression(max_iter=2000, random_state=RANDOM_STATE)),
            ]
        ),
        "random_forest": Pipeline(
            [
                ("prep", make_preprocessor(scale_numeric=False)),
                (
                    "clf",
                    RandomForestClassifier(
                        n_estimators=400,
                        min_samples_leaf=2,
                        class_weight="balanced",
                        random_state=RANDOM_STATE,
                        n_jobs=-1,
                    ),
                ),
            ]
        ),
        "hist_gradient_boosting": Pipeline(
            [
                ("prep", make_preprocessor(scale_numeric=False)),
                (
                    "clf",
                    HistGradientBoostingClassifier(
                        max_iter=400,
                        learning_rate=0.08,
                        max_leaf_nodes=31,
                        l2_regularization=1.0,
                        random_state=RANDOM_STATE,
                    ),
                ),
            ]
        ),
    }


def ordinal_error(y_true: pd.Series, y_pred: np.ndarray) -> float:
    """Mean number of bands each prediction is off by. Confusing Normal with
    High is a far worse failure than confusing Low with Medium, and plain
    accuracy hides that distinction."""
    index = {label: i for i, label in enumerate(RISK_ORDER)}
    true_i = np.array([index[v] for v in y_true])
    pred_i = np.array([index[v] for v in y_pred])
    return float(np.abs(true_i - pred_i).mean())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).resolve().parent
    parser.add_argument("--data", type=Path, default=here.parent / "Health_Risk_Dataset.csv")
    parser.add_argument("--out", type=Path, default=here / "artifacts")
    parser.add_argument("--test-size", type=float, default=0.2)
    args = parser.parse_args()

    X, y = load_dataset(args.data)
    print(f"Loaded {len(X)} rows from {args.data}")
    print("Class balance:", y.value_counts().reindex(RISK_ORDER).to_dict(), "\n")

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=args.test_size, stratify=y, random_state=RANDOM_STATE
    )

    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=RANDOM_STATE)
    scores: dict[str, float] = {}
    for name, pipeline in candidates().items():
        fold_scores = cross_val_score(
            pipeline, X_train, y_train, cv=cv, scoring="f1_macro", n_jobs=-1
        )
        scores[name] = float(fold_scores.mean())
        print(f"{name:>24}  cv macro-F1 = {fold_scores.mean():.4f} ± {fold_scores.std():.4f}")

    best_name = max(scores, key=scores.__getitem__)
    print(f"\nSelected: {best_name}\n")

    model = candidates()[best_name]
    model.fit(X_train, y_train)

    y_pred = model.predict(X_test)
    print(classification_report(y_test, y_pred, labels=RISK_ORDER, zero_division=0))
    print("Confusion matrix (rows = actual, cols = predicted; order "
          f"{RISK_ORDER}):")
    print(confusion_matrix(y_test, y_pred, labels=RISK_ORDER))
    test_f1 = float(f1_score(y_test, y_pred, average="macro"))
    test_acc = float((y_pred == y_test.to_numpy()).mean())
    off_by = ordinal_error(y_test, y_pred)
    print(f"\nheld-out accuracy      = {test_acc:.4f}")
    print(f"held-out macro-F1      = {test_f1:.4f}")
    print(f"mean bands off         = {off_by:.4f}")

    # Refit on everything before shipping: the held-out split has served its
    # purpose as an honest estimate, and the API should get every row.
    final = candidates()[best_name]
    final.fit(X, y)

    args.out.mkdir(parents=True, exist_ok=True)
    model_path = args.out / "model.joblib"
    joblib.dump(final, model_path)

    metadata = {
        "model": best_name,
        "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "dataset": str(args.data.name),
        "n_rows": int(len(X)),
        "features": FEATURE_COLUMNS,
        "classes": [str(c) for c in final.classes_],
        "risk_order": RISK_ORDER,
        "cv_macro_f1": scores,
        "holdout": {
            "accuracy": test_acc,
            "macro_f1": test_f1,
            "mean_bands_off": off_by,
        },
    }
    (args.out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"\nWrote {model_path} and {args.out / 'metadata.json'}")


if __name__ == "__main__":
    main()
