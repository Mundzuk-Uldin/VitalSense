"""Feature definitions shared by training and serving.

Keeping this in one place is what stops the classic skew bug where the API
builds its feature row in a slightly different order than the trainer did.
"""

from __future__ import annotations

import pandas as pd

import news2

# Order matters: the model was fitted on a frame with exactly these columns.
NUMERIC_FEATURES = [
    "Respiratory_Rate",
    "Oxygen_Saturation",
    "O2_Scale",
    "Systolic_BP",
    "Heart_Rate",
    "Temperature",
    "On_Oxygen",
]
CATEGORICAL_FEATURES = ["Consciousness"]

# Derived from the NEWS2 rulebook. The raw vitals alone force the trees to
# rediscover the clinical cut-points by brute force; handing them the
# sub-scores lets a shallow model learn the banding directly, and the
# "how many vitals are abnormal" count captures the dataset's own rule that
# three mildly-off vitals is a Medium even when the aggregate is low.
DERIVED_FEATURES = ["NEWS2_Total", "NEWS2_Max_Component", "NEWS2_Abnormal_Count"]

FEATURE_COLUMNS = NUMERIC_FEATURES + DERIVED_FEATURES + CATEGORICAL_FEATURES

TARGET = "Risk_Level"

# Ordered from least to most acute; used for ordinal-aware error reporting
# and for the confusion matrix axes.
RISK_ORDER = ["Normal", "Low", "Medium", "High"]


def add_derived(frame: pd.DataFrame) -> pd.DataFrame:
    """Append the NEWS2-derived columns to a frame of raw vitals."""
    frame = frame.copy()
    totals, maxima, abnormal = [], [], []
    for row in frame.itertuples(index=False):
        comps = news2.components(
            respiratory_rate=row.Respiratory_Rate,
            oxygen_saturation=row.Oxygen_Saturation,
            o2_scale=row.O2_Scale,
            systolic_bp=row.Systolic_BP,
            heart_rate=row.Heart_Rate,
            temperature=row.Temperature,
            consciousness=row.Consciousness,
            on_oxygen=row.On_Oxygen,
        )
        scores = [c.score for c in comps]
        totals.append(sum(scores))
        maxima.append(max(scores))
        abnormal.append(sum(1 for s in scores if s > 0))
    frame["NEWS2_Total"] = totals
    frame["NEWS2_Max_Component"] = maxima
    frame["NEWS2_Abnormal_Count"] = abnormal
    return frame


def build_row(vitals: dict) -> pd.DataFrame:
    """Turn a single reading (API-shaped dict) into a one-row model input."""
    frame = pd.DataFrame(
        [
            {
                "Respiratory_Rate": vitals["respiratory_rate"],
                "Oxygen_Saturation": vitals["oxygen_saturation"],
                "O2_Scale": int(vitals["o2_scale"]),
                "Systolic_BP": vitals["systolic_bp"],
                "Heart_Rate": vitals["heart_rate"],
                "Temperature": vitals["temperature"],
                "On_Oxygen": int(bool(vitals["on_oxygen"])),
                "Consciousness": str(vitals["consciousness"]).upper(),
            }
        ]
    )
    return add_derived(frame)[FEATURE_COLUMNS]
