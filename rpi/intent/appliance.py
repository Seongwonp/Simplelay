"""Appliance button-map manifests: the known button vocabulary for one device.

Loads ``docs/button-maps/<appliance>.json`` (already produced for the app's
coordinate mapping) so the intent layer can validate a resolver's output
against real buttons instead of trusting it blindly.
"""

import json
from rpi.controller.models import button_behavior
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


class ApplianceManifestError(ValueError):
    """Raised when a button-map JSON file is missing fields or malformed."""


@dataclass(frozen=True)
class ButtonSpec:
    id: str
    label: str
    x: int
    y: int
    behavior: str = "unknown"


@dataclass(frozen=True)
class ApplianceManifest:
    appliance: str
    model: str
    buttons: tuple[ButtonSpec, ...]

    @property
    def labels(self) -> frozenset[str]:
        """The button-label vocabulary a resolver's output must stay within."""
        return frozenset(button.label for button in self.buttons)

    def label_for(self, button_id: str) -> str:
        for button in self.buttons:
            if button.id == button_id:
                return button.label
        raise KeyError(f"unknown button id: {button_id}")


def load_button_map(path: Path | str) -> ApplianceManifest:
    """Parse and validate one button-map JSON file into an ApplianceManifest."""
    raw_text = Path(path).read_text(encoding="utf-8")
    try:
        data: Mapping[str, object] = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise ApplianceManifestError(f"invalid JSON in {path}: {exc}") from exc

    try:
        appliance = str(data["appliance"]).strip()
        model = str(data["model"]).strip()
        raw_buttons = data["buttons"]
    except KeyError as exc:
        raise ApplianceManifestError(f"{path} is missing required field {exc}") from exc

    if not appliance:
        raise ApplianceManifestError(f"{path}: appliance must not be blank")
    if not isinstance(raw_buttons, list) or not raw_buttons:
        raise ApplianceManifestError(f"{path}: buttons must be a non-empty list")

    buttons: list[ButtonSpec] = []
    seen_ids: set[str] = set()
    for entry in raw_buttons:
        try:
            button_id = str(entry["id"]).strip()
            label = str(entry["label"]).strip()
            x = int(entry["x"])
            y = int(entry["y"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ApplianceManifestError(
                f"{path}: malformed button entry {entry!r}"
            ) from exc
        if not button_id or not label:
            raise ApplianceManifestError(
                f"{path}: button id and label must not be blank"
            )
        if button_id in seen_ids:
            raise ApplianceManifestError(f"{path}: duplicate button id {button_id!r}")
        seen_ids.add(button_id)
        buttons.append(ButtonSpec(button_id, label, x, y, button_behavior(entry.get("behavior"))))

    return ApplianceManifest(appliance, model, tuple(buttons))
