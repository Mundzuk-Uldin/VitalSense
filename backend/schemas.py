"""Request and response models for the risk API."""

from __future__ import annotations

from datetime import datetime
from typing import Literal, Optional

from pydantic import BaseModel, Field

Consciousness = Literal["A", "C", "V", "P", "U"]

# Vitals an Apple Watch cannot measure. The watch posts what its sensors
# give it; these carry the clinically normal default so a watch-only payload
# is still scoreable, and the iPhone app overrides them when a human has
# entered something better.
DEFAULT_SYSTOLIC_BP = 120.0
DEFAULT_CONSCIOUSNESS: Consciousness = "A"
DEFAULT_O2_SCALE = 1
DEFAULT_ON_OXYGEN = False


class VitalsIn(BaseModel):
    respiratory_rate: float = Field(..., ge=0, le=80, description="Breaths per minute")
    oxygen_saturation: float = Field(..., ge=50, le=100, description="SpO2, percent")
    heart_rate: float = Field(..., ge=20, le=250, description="Beats per minute")
    temperature: float = Field(..., ge=25, le=45, description="Body temperature, °C")

    systolic_bp: float = Field(
        DEFAULT_SYSTOLIC_BP, ge=40, le=300, description="mmHg; not measurable by Apple Watch"
    )
    o2_scale: Literal[1, 2] = Field(
        DEFAULT_O2_SCALE,
        description="NEWS2 SpO2 scale. 2 is for target range 88-92% "
        "(hypercapnic respiratory failure).",
    )
    consciousness: Consciousness = Field(
        DEFAULT_CONSCIOUSNESS,
        description="ACVPU: Alert, new Confusion, Voice, Pain, Unresponsive",
    )
    on_oxygen: bool = Field(DEFAULT_ON_OXYGEN, description="Receiving supplemental oxygen")

    # Free-form provenance so the iPhone can tell a live watch reading apart
    # from a hand-typed one when it displays the history.
    source: Optional[str] = Field(None, max_length=64, description="e.g. 'apple_watch'")
    recorded_at: Optional[datetime] = None

    model_config = {
        "json_schema_extra": {
            "example": {
                "respiratory_rate": 22,
                "oxygen_saturation": 94,
                "heart_rate": 112,
                "temperature": 38.4,
                "systolic_bp": 104,
                "o2_scale": 1,
                "consciousness": "A",
                "on_oxygen": False,
                "source": "apple_watch",
            }
        }
    }


class RiskFactor(BaseModel):
    """One vital's contribution to the score, in a form a UI can render."""

    name: str
    label: str
    value: float
    display_value: str
    score: int
    severity: Literal["normal", "mild", "moderate", "severe"]
    note: str


class PredictionOut(BaseModel):
    risk_level: Literal["Normal", "Low", "Medium", "High"]
    confidence: float = Field(..., ge=0, le=1)
    probabilities: dict[str, float]

    news2_total: int
    news2_band: str
    has_red_score: bool = Field(
        ..., description="True when any single vital scores 3, which escalates on its own"
    )

    risk_factors: list[RiskFactor] = Field(
        ..., description="All seven vitals, most concerning first"
    )
    top_factors: list[str] = Field(..., description="Human-readable drivers of this score")
    recommendation: str

    model_version: str
    predicted_at: datetime
    inputs: VitalsIn


class ModelInfo(BaseModel):
    model: str
    trained_at: str
    dataset: str
    n_rows: int
    classes: list[str]
    risk_order: list[str]
    features: list[str]
    cv_macro_f1: dict[str, float]
    holdout: dict[str, float]
