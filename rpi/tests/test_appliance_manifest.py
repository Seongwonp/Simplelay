from pathlib import Path

import pytest

from rpi.intent import ApplianceManifestError, load_button_map

REPO_ROOT = Path(__file__).resolve().parents[2]
MICROWAVE_MAP = REPO_ROOT / "docs" / "button-maps" / "microwave.json"


def test_loads_real_microwave_button_map():
    manifest = load_button_map(MICROWAVE_MAP)

    assert manifest.appliance == "microwave"
    assert manifest.model == "generic"
    assert len(manifest.buttons) == 9
    assert "해동" in manifest.labels
    assert "시작" in manifest.labels
    assert manifest.label_for("BT-07") == "해동"


def test_label_for_unknown_id_raises_key_error():
    manifest = load_button_map(MICROWAVE_MAP)

    with pytest.raises(KeyError):
        manifest.label_for("BT-99")


def test_missing_file_raises_file_not_found(tmp_path: Path):
    with pytest.raises(FileNotFoundError):
        load_button_map(tmp_path / "missing.json")


def test_invalid_json_raises_manifest_error(tmp_path: Path):
    path = tmp_path / "broken.json"
    path.write_text("{not json", encoding="utf-8")

    with pytest.raises(ApplianceManifestError):
        load_button_map(path)


def test_missing_required_field_raises_manifest_error(tmp_path: Path):
    path = tmp_path / "incomplete.json"
    path.write_text('{"appliance": "microwave"}', encoding="utf-8")

    with pytest.raises(ApplianceManifestError):
        load_button_map(path)


def test_empty_buttons_list_raises_manifest_error(tmp_path: Path):
    path = tmp_path / "empty.json"
    path.write_text(
        '{"appliance": "microwave", "model": "generic", "buttons": []}',
        encoding="utf-8",
    )

    with pytest.raises(ApplianceManifestError):
        load_button_map(path)


def test_duplicate_button_id_raises_manifest_error(tmp_path: Path):
    path = tmp_path / "dupes.json"
    path.write_text(
        """
        {
          "appliance": "microwave",
          "model": "generic",
          "buttons": [
            {"id": "BT-01", "label": "10초", "x": 0, "y": 0},
            {"id": "BT-01", "label": "30초", "x": 1, "y": 0}
          ]
        }
        """,
        encoding="utf-8",
    )

    with pytest.raises(ApplianceManifestError):
        load_button_map(path)


def test_blank_label_raises_manifest_error(tmp_path: Path):
    path = tmp_path / "blank_label.json"
    path.write_text(
        """
        {
          "appliance": "microwave",
          "model": "generic",
          "buttons": [{"id": "BT-01", "label": "  ", "x": 0, "y": 0}]
        }
        """,
        encoding="utf-8",
    )

    with pytest.raises(ApplianceManifestError):
        load_button_map(path)
