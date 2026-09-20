"""FastAPI service exposing the health-risk model.

    uvicorn main:app --host 0.0.0.0 --port 8000

Binding to 0.0.0.0 is what lets an iPhone on the same Wi-Fi reach it.
Interactive docs are at /docs.
"""

from __future__ import annotations

import json
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

import joblib
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

import news2
from features import RISK_ORDER, build_row
from schemas import ModelInfo, PredictionOut, RiskFactor, VitalsIn

ARTIFACTS = Path(__file__).resolve().parent / "artifacts"

logger = logging.getLogger("uvicorn.error")

LABELS = {
    "respiratory_rate": "Respiratory rate",
    "oxygen_saturation": "Oxygen saturation",
    "on_oxygen": "Supplemental oxygen",
    "systolic_bp": "Systolic blood pressure",
    "heart_rate": "Heart rate",
    "temperature": "Temperature",
    "consciousness": "Consciousness",
}

SEVERITY = {0: "normal", 1: "mild", 2: "moderate", 3: "severe"}

RECOMMENDATIONS = {
    "Normal": "All vitals within range. Continue routine monitoring.",
    "Low": "Minor deviation. Repeat observations within 4-6 hours.",
    "Medium": "Escalate to a registered nurse. Hourly observations; "
    "urgent review by a clinician competent in acute illness.",
    "High": "Emergency response. Continuous monitoring and immediate "
    "assessment by a critical-care-capable team.",
}

# Wording for a vital that is off but has no NEWS2 points of its own, so the
# UI still has something to say about it.
NORMAL_NOTE = "Within normal range."


class ModelBundle:
    """Holds the fitted pipeline and its metadata for the lifetime of the app."""

    def __init__(self) -> None:
        self.pipeline = None
        self.metadata: dict = {}

    def load(self) -> None:
        model_path = ARTIFACTS / "model.joblib"
        meta_path = ARTIFACTS / "metadata.json"
        if not model_path.exists():
            raise RuntimeError(
                f"No model at {model_path}. Run `python train.py` first."
            )
        self.pipeline = joblib.load(model_path)
        self.metadata = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        logger.info(
            "Loaded %s trained %s",
            self.metadata.get("model", "model"),
            self.metadata.get("trained_at", "(unknown)"),
        )

    @property
    def version(self) -> str:
        return f"{self.metadata.get('model', 'unknown')}@{self.metadata.get('trained_at', 'unknown')}"


bundle = ModelBundle()


@asynccontextmanager
async def lifespan(app: FastAPI):
    bundle.load()
    yield


app = FastAPI(
    title="Health Risk API",
    version="1.0.0",
    description="Predicts a NEWS2-style risk level from vitals, and explains "
    "which vitals drove it.",
    lifespan=lifespan,
)

# The iOS app talks to this over the local network from an arbitrary origin.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def _risk_factors(vitals: VitalsIn) -> tuple[list[RiskFactor], list[news2.Component]]:
    comps = news2.components(
        respiratory_rate=vitals.respiratory_rate,
        oxygen_saturation=vitals.oxygen_saturation,
        o2_scale=vitals.o2_scale,
        systolic_bp=vitals.systolic_bp,
        heart_rate=vitals.heart_rate,
        temperature=vitals.temperature,
        consciousness=vitals.consciousness,
        on_oxygen=vitals.on_oxygen,
    )
    factors = [
        RiskFactor(
            name=c.name,
            label=LABELS[c.name],
            value=c.value,
            display_value=c.detail,
            score=c.score,
            severity=SEVERITY[c.score],
            note=(
                NORMAL_NOTE
                if c.score == 0
                else f"{c.detail.capitalize()} contributes {c.score} "
                f"point{'s' if c.score != 1 else ''} to the early-warning score."
            ),
        )
        for c in comps
    ]
    # Most concerning first, then alphabetically so the order is stable
    # between identical readings.
    factors.sort(key=lambda f: (-f.score, f.label))
    return factors, comps


@app.get("/health", summary="Liveness probe")
def health() -> dict:
    return {
        "status": "ok" if bundle.pipeline is not None else "model not loaded",
        "model_version": bundle.version,
    }


@app.get("/model", response_model=ModelInfo, summary="Model card")
def model_info() -> ModelInfo:
    if not bundle.metadata:
        raise HTTPException(503, "Model metadata unavailable; run train.py")
    return ModelInfo(**bundle.metadata)


@app.post("/predict", response_model=PredictionOut, summary="Score one reading")
def predict(vitals: VitalsIn) -> PredictionOut:
    if bundle.pipeline is None:
        raise HTTPException(503, "Model not loaded")

    row = build_row(vitals.model_dump())
    proba = bundle.pipeline.predict_proba(row)[0]
    classes = list(bundle.pipeline.classes_)
    probabilities = {str(c): float(p) for c, p in zip(classes, proba)}
    risk_level = max(probabilities, key=probabilities.__getitem__)

    factors, comps = _risk_factors(vitals)
    contributing = [f for f in factors if f.score > 0]
    top = [f"{f.label}: {f.display_value}" for f in contributing[:3]] or [
        "No vital is outside its normal range."
    ]

    return PredictionOut(
        risk_level=risk_level,
        confidence=probabilities[risk_level],
        probabilities={k: probabilities.get(k, 0.0) for k in RISK_ORDER},
        news2_total=news2.aggregate(comps),
        news2_band=news2.band(comps),
        has_red_score=news2.has_red_score(comps),
        risk_factors=factors,
        top_factors=top,
        recommendation=RECOMMENDATIONS[risk_level],
        model_version=bundle.version,
        predicted_at=datetime.now(timezone.utc),
        inputs=vitals,
    )


@app.post("/predict/batch", response_model=list[PredictionOut], summary="Score many readings")
def predict_batch(readings: list[VitalsIn]) -> list[PredictionOut]:
    if len(readings) > 500:
        raise HTTPException(413, "Send at most 500 readings per request")
    return [predict(r) for r in readings]
