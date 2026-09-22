"""NEWS2 (National Early Warning Score 2) scoring.

The model is the thing that makes the prediction, but a gradient-boosted tree
cannot tell a nurse *why* a patient scored High. NEWS2 can: it is the scoring
system the dataset's vitals are drawn from, it is published by the RCP, and it
decomposes cleanly into one sub-score per vital. We use it purely as the
explainability layer -- "which vitals are driving this?" -- alongside the
model's own probabilities.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict

# Consciousness levels. Anything other than Alert is "CVPU" and scores 3.
ALERT = "A"
CONSCIOUSNESS_LEVELS = {
    "A": "Alert",
    "C": "New confusion",
    "V": "Responds to voice",
    "P": "Responds to pain",
    "U": "Unresponsive",
}


@dataclass(frozen=True)
class Component:
    """One vital's contribution to the aggregate score."""

    name: str
    value: float
    score: int
    detail: str

    def as_dict(self) -> dict:
        return asdict(self)


def _respiratory_rate(rr: float) -> int:
    if rr <= 8:
        return 3
    if rr <= 11:
        return 1
    if rr <= 20:
        return 0
    if rr <= 24:
        return 2
    return 3


def _spo2_scale_1(spo2: float) -> int:
    if spo2 <= 91:
        return 3
    if spo2 <= 93:
        return 2
    if spo2 <= 95:
        return 1
    return 0


def _spo2_scale_2(spo2: float, on_oxygen: bool) -> int:
    """Scale 2 is for patients in hypercapnic respiratory failure, whose
    target range is 88-92%. Above that range they are penalised, but only
    while on supplemental oxygen."""
    if spo2 <= 83:
        return 3
    if spo2 <= 85:
        return 2
    if spo2 <= 87:
        return 1
    if spo2 <= 92:
        return 0
    if not on_oxygen:
        return 0
    if spo2 <= 94:
        return 1
    if spo2 <= 96:
        return 2
    return 3


def _systolic_bp(sbp: float) -> int:
    if sbp <= 90:
        return 3
    if sbp <= 100:
        return 2
    if sbp <= 110:
        return 1
    if sbp <= 219:
        return 0
    return 3


def _heart_rate(hr: float) -> int:
    if hr <= 40:
        return 3
    if hr <= 50:
        return 1
    if hr <= 90:
        return 0
    if hr <= 110:
        return 1
    if hr <= 130:
        return 2
    return 3


def _temperature(temp: float) -> int:
    if temp <= 35.0:
        return 3
    if temp <= 36.0:
        return 1
    if temp <= 38.0:
        return 0
    if temp <= 39.0:
        return 1
    return 2


def components(
    respiratory_rate: float,
    oxygen_saturation: float,
    o2_scale: int,
    systolic_bp: float,
    heart_rate: float,
    temperature: float,
    consciousness: str,
    on_oxygen: bool,
) -> list[Component]:
    on_oxygen = bool(on_oxygen)
    spo2_score = (
        _spo2_scale_2(oxygen_saturation, on_oxygen)
        if int(o2_scale) == 2
        else _spo2_scale_1(oxygen_saturation)
    )
    conscious_score = 0 if consciousness.upper() == ALERT else 3

    return [
        Component(
            "respiratory_rate",
            respiratory_rate,
            _respiratory_rate(respiratory_rate),
            f"{respiratory_rate:.0f} breaths/min",
        ),
        Component(
            "oxygen_saturation",
            oxygen_saturation,
            spo2_score,
            f"{oxygen_saturation:.0f}% (scale {int(o2_scale)})",
        ),
        Component(
            "on_oxygen",
            float(on_oxygen),
            2 if on_oxygen else 0,
            "supplemental oxygen" if on_oxygen else "breathing room air",
        ),
        Component(
            "systolic_bp", systolic_bp, _systolic_bp(systolic_bp), f"{systolic_bp:.0f} mmHg"
        ),
        Component("heart_rate", heart_rate, _heart_rate(heart_rate), f"{heart_rate:.0f} bpm"),
        Component("temperature", temperature, _temperature(temperature), f"{temperature:.1f} °C"),
        Component(
            "consciousness",
            float(conscious_score),
            conscious_score,
            CONSCIOUSNESS_LEVELS.get(consciousness.upper(), consciousness),
        ),
    ]


def aggregate(comps: list[Component]) -> int:
    return sum(c.score for c in comps)


def has_red_score(comps: list[Component]) -> bool:
    """A 3 in any single parameter is a "red score" and escalates the band
    regardless of how low the aggregate is."""
    return any(c.score >= 3 for c in comps)


def band(comps: list[Component]) -> str:
    """Map the aggregate onto the dataset's four risk labels."""
    total = aggregate(comps)
    if total == 0:
        return "Normal"
    if total >= 7:
        return "High"
    if total >= 5:
        return "Medium"
    if has_red_score(comps):
        return "Medium"
    return "Low"
