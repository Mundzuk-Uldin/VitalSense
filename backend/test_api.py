"""Smoke tests for the risk service.

    pip install pytest httpx
    pytest -q
"""

from __future__ import annotations

import pandas as pd
import pytest
from fastapi.testclient import TestClient

import news2
from features import RISK_ORDER, TARGET, add_derived
from main import app

WATCH_ONLY = {
    "respiratory_rate": 16,
    "oxygen_saturation": 98,
    "heart_rate": 68,
    "temperature": 36.8,
}


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as client:
        yield client


def test_health(client):
    assert client.get("/health").json()["status"] == "ok"


def test_watch_only_payload_uses_defaults(client):
    """The watch cannot measure blood pressure or consciousness, so a payload
    without them must still score rather than 422."""
    body = client.post("/predict", json=WATCH_ONLY).json()
    assert body["risk_level"] == "Normal"
    assert body["inputs"]["systolic_bp"] == 120
    assert body["inputs"]["consciousness"] == "A"


def test_deteriorating_vitals_raise_the_band(client):
    """Monotonicity is the property that actually matters clinically: a
    sicker set of vitals must never score lower."""
    ladders = [
        WATCH_ONLY,
        {**WATCH_ONLY, "respiratory_rate": 22, "heart_rate": 95},
        {**WATCH_ONLY, "respiratory_rate": 25, "heart_rate": 115, "oxygen_saturation": 93},
        {
            **WATCH_ONLY,
            "respiratory_rate": 29,
            "heart_rate": 135,
            "oxygen_saturation": 89,
            "temperature": 39.4,
            "systolic_bp": 85,
            "consciousness": "V",
        },
    ]
    severities = []
    for payload in ladders:
        body = client.post("/predict", json=payload).json()
        severities.append(RISK_ORDER.index(body["risk_level"]))
    assert severities == sorted(severities), severities
    assert severities[0] == 0 and severities[-1] == 3


def test_probabilities_are_a_distribution(client):
    body = client.post("/predict", json=WATCH_ONLY).json()
    assert set(body["probabilities"]) == set(RISK_ORDER)
    assert sum(body["probabilities"].values()) == pytest.approx(1.0, abs=1e-6)
    assert body["confidence"] == pytest.approx(max(body["probabilities"].values()))


def test_risk_factors_cover_every_vital_and_are_ordered(client):
    body = client.post("/predict", json={**WATCH_ONLY, "heart_rate": 132, "temperature": 39.5})
    factors = body.json()["risk_factors"]
    assert len(factors) == 7
    scores = [f["score"] for f in factors]
    assert scores == sorted(scores, reverse=True)
    heart = next(f for f in factors if f["name"] == "heart_rate")
    assert heart["score"] == 3 and heart["severity"] == "severe"


def test_out_of_range_input_is_rejected(client):
    assert client.post("/predict", json={**WATCH_ONLY, "oxygen_saturation": 140}).status_code == 422
    assert client.post("/predict", json={**WATCH_ONLY, "consciousness": "Z"}).status_code == 422


def test_o2_scale_2_tolerates_lower_saturation(client):
    """A COPD patient at 90% is at target on scale 2, but penalised on
    scale 1. The model must reflect that."""
    low_sat = {**WATCH_ONLY, "oxygen_saturation": 90}
    scale_1 = client.post("/predict", json={**low_sat, "o2_scale": 1}).json()
    scale_2 = client.post("/predict", json={**low_sat, "o2_scale": 2}).json()
    assert scale_2["news2_total"] < scale_1["news2_total"]


def test_batch_matches_individual_calls(client):
    payloads = [WATCH_ONLY, {**WATCH_ONLY, "heart_rate": 140}]
    batch = client.post("/predict/batch", json=payloads).json()
    singles = [client.post("/predict", json=p).json() for p in payloads]
    assert [b["risk_level"] for b in batch] == [s["risk_level"] for s in singles]


def test_model_reproduces_the_dataset():
    """The shipped model is refit on every row, so it should agree with the
    labels it was trained on. A regression here means the serving feature
    pipeline has drifted from the training one."""
    import joblib
    from pathlib import Path

    from features import FEATURE_COLUMNS

    pipeline = joblib.load(Path(__file__).parent / "artifacts" / "model.joblib")
    frame = add_derived(pd.read_csv(Path(__file__).parent.parent / "Health_Risk_Dataset.csv"))
    predicted = pipeline.predict(frame[FEATURE_COLUMNS])
    accuracy = (predicted == frame[TARGET]).mean()
    assert accuracy > 0.99, accuracy


def test_serving_path_matches_the_training_path(client):
    """Catch train/serve skew: score a real dataset row through the HTTP API
    and check it lands on that row's label."""
    frame = pd.read_csv("../Health_Risk_Dataset.csv")
    mismatches = []
    for row in frame.sample(60, random_state=7).itertuples():
        body = client.post(
            "/predict",
            json={
                "respiratory_rate": row.Respiratory_Rate,
                "oxygen_saturation": row.Oxygen_Saturation,
                "o2_scale": int(row.O2_Scale),
                "systolic_bp": row.Systolic_BP,
                "heart_rate": row.Heart_Rate,
                "temperature": row.Temperature,
                "consciousness": row.Consciousness,
                "on_oxygen": bool(row.On_Oxygen),
            },
        ).json()
        if body["risk_level"] != row.Risk_Level:
            mismatches.append((row.Patient_ID, row.Risk_Level, body["risk_level"]))
    assert not mismatches, mismatches


def test_news2_band_agrees_with_the_published_rulebook():
    """Guards the explainability layer independently of the model."""
    comps = news2.components(
        respiratory_rate=28,
        oxygen_saturation=91,
        o2_scale=1,
        systolic_bp=88,
        heart_rate=132,
        temperature=38.9,
        consciousness="V",
        on_oxygen=True,
    )
    assert news2.aggregate(comps) == 18
    assert news2.band(comps) == "High"
    assert news2.has_red_score(comps)
