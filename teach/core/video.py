"""Video de un path de carrera: guion (AI, grounded en el catálogo) + render.

Dos pasos separados, igual que el resto del contenido generado:

  generate_script()  la AI escribe el guion a partir de los datos reales del
                      path (certs, exámenes, vigencias, orden). Se congela en
                      media/paths/<slug>/<lang>/script.yaml — editable a mano
                      después, como content.md.
  render_video()      determinístico y repetible, no llama a la AI: Pillow
                      dibuja las slides, Piper (TTS neuronal local) narra,
                      ffmpeg arma el mp4. Se puede rehacer sin gastar cuota.

La escena "path" (el mapa de certificaciones) nunca la escribe la AI: se arma
directo desde catalog.yaml para que el dato más sensible a errores (exámenes,
vigencias, orden) nunca dependa de que el modelo no alucine.
"""

import re
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import httpx
import yaml
from PIL import Image, ImageDraw, ImageFont

from . import catalog, certs
from .generator import LANG_NAMES, make_completer

W, H = 1920, 1080
BG = (13, 17, 23)
FG = (235, 238, 245)
MUTED = (150, 160, 175)
ACCENT = (74, 127, 212)
ACCENT2 = (122, 95, 212)
GOLD = (212, 169, 74)

FONT_BOLD = Path("/usr/share/fonts/liberation-sans-fonts/LiberationSans-Bold.ttf")
FONT_REGULAR = Path("/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf")

VOICE_CACHE = Path.home() / ".cache" / "teach-plat" / "piper-voices"
HF_BASE = "https://huggingface.co/rhasspy/piper-voices/resolve/main"
# un idioma por vez a medida que se valida la voz; sumar acá para habilitarlo
VOICES = {
    "es": "es/es_AR/daniela/high/es_AR-daniela-high",
    "en": "en/en_US/amy/medium/en_US-amy-medium",
}

SCENES = [
    {"id": "hook", "kind": "title"},
    {"id": "audience", "kind": "bullets"},
    {"id": "learn", "kind": "bullets"},
    {"id": "path", "kind": "path"},
    {"id": "outcomes", "kind": "bullets"},
    {"id": "platform", "kind": "bullets"},
    {"id": "cta", "kind": "title"},
]
AI_SCENE_IDS = [s["id"] for s in SCENES if s["id"] != "path"]


class VideoError(Exception):
    pass


def media_dir(path_slug: str, lang: str) -> Path:
    return catalog.root() / "media" / "paths" / path_slug / lang


# --------------------------------------------------------------- guion (AI)

def _resolve_stages(path: dict) -> list[list[dict]]:
    entries = catalog.load().get("certs", {})
    stages = []
    for stage in path.get("steps", []):
        resolved = [
            {
                "id": cert_id,
                "name": entries.get(cert_id, {}).get("name", cert_id),
                "exam": entries.get(cert_id, {}).get("exam", ""),
                "validity": entries.get(cert_id, {}).get("validity", ""),
            }
            for cert_id in stage
        ]
        stages.append(resolved)
    return stages


def _localized_path(path: dict, lang: str) -> dict:
    if lang == certs.DEFAULT_LANG:
        return path
    translated = (path.get("i18n") or {}).get(lang) or {}
    return {**path, **translated}


def _path_voiceover(stages: list[list[dict]], lang: str) -> str:
    names = [" o ".join(c["name"] for c in stage) for stage in stages]
    if lang == "en":
        return "You start with " + ", then move to ".join(names) + "."
    return "Arrancás con " + ", después seguís con ".join(names) + "."


def _ask_scenes(system: str, user: str, backend: str | None) -> dict:
    complete, backend_meta = make_completer(backend)
    raw = complete(system, user).strip()
    raw = re.sub(r"^```[a-z]*\n?|\n?```$", "", raw).strip()
    data = yaml.safe_load(raw)
    if not isinstance(data, dict):
        raise VideoError(f"La AI no devolvió YAML estructurado:\n{raw[:300]}")
    missing = [key for key in AI_SCENE_IDS if not isinstance(data.get(key), dict)]
    if missing:
        raise VideoError(f"Guion incompleto, faltan escenas {missing}:\n{raw[:500]}")
    return data, backend_meta


def generate_script(
    path_slug: str,
    backend: str | None = None,
    lang: str = certs.DEFAULT_LANG,
    force: bool = False,
) -> dict:
    if lang not in certs.LANGS:
        raise VideoError(f"Idioma '{lang}' no soportado. Válidos: {certs.LANGS}")
    paths = catalog.load().get("paths", {})
    path = paths.get(path_slug)
    if path is None:
        raise VideoError(f"Path '{path_slug}' no existe en el catálogo (ver catalog.yaml paths)")

    out_dir = media_dir(path_slug, lang)
    script_path = out_dir / "script.yaml"
    if script_path.exists() and not force:
        return {"skipped": f"guion ya existe en {script_path} (usar --force)"}

    localized = _localized_path(path, lang)
    stages = _resolve_stages(path)
    stage_lines = [
        f"  Paso {i}: " + " / ".join(f"{c['name']} (examen {c['exam']}, vigencia {c['validity']})" for c in stage)
        for i, stage in enumerate(stages, 1)
    ]
    context = (
        f"Path de carrera: {localized.get('name')}\n"
        f"Descripción oficial: {localized.get('description')}\n"
        "Certificaciones en orden (dato real, no inventar otras ni cambiar el orden):\n"
        + "\n".join(stage_lines)
    )

    system = (
        "Sos guionista de videos de marketing educativo estilo YouTube, para una "
        f"plataforma de certificaciones IT llamada 'Cert Landscape'. Escribís en "
        f"{LANG_NAMES.get(lang, lang)}. Tono cercano, motivador y directo, sin "
        "exagerar ni prometer de más. Te basás SOLO en los datos reales que te "
        "pasan (nombres de examen, vigencias, orden); nunca inventás cifras de "
        "salario ni estadísticas que no te dieron. Respondé SOLO con YAML válido, "
        "sin fences ni comentarios."
    )
    user = (
        f"{context}\n\n"
        "Escribí el guion de un video corto (2 a 3 minutos) sobre este path de "
        "carrera. Devolvé YAML con EXACTAMENTE estas claves (una por escena):\n\n"
        "hook:\n"
        "  title: <gancho de 4 a 8 palabras>\n"
        "  voiceover: <2 o 3 frases que enganchen y planteen para qué sirve esta ruta>\n"
        "audience:\n"
        "  title: <título corto, ej. 'Para quién es'>\n"
        "  voiceover: <2 o 3 frases>\n"
        "  bullets: [<perfil 1>, <perfil 2>, <perfil 3>]\n"
        "learn:\n"
        "  title: <título corto, ej. 'Qué vas a aprender'>\n"
        "  voiceover: <2 o 3 frases>\n"
        "  bullets: [<tema 1>, <tema 2>, <tema 3>, <tema 4>]\n"
        "outcomes:\n"
        "  title: <título corto, ej. 'Qué salida laboral te da'>\n"
        "  voiceover: <2 o 3 frases sobre roles/tareas reales que habilita, sin inventar sueldos>\n"
        "  bullets: [<rol 1>, <rol 2>, <rol 3>]\n"
        "platform:\n"
        "  title: <título corto sobre cómo estudiarlo acá>\n"
        "  voiceover: <2 o 3 frases: el contenido se genera con AI a partir de fuentes "
        "oficiales, con ejercicios y labs de romper-y-arreglar, en varios idiomas>\n"
        "  bullets: [<feature 1>, <feature 2>, <feature 3>]\n"
        "cta:\n"
        "  title: <llamado a la acción corto>\n"
        "  voiceover: <1 o 2 frases de cierre invitando a empezar en la plataforma>\n"
    )
    ai_scenes, backend_meta = _ask_scenes(system, user, backend)

    scenes = {key: ai_scenes[key] for key in AI_SCENE_IDS}
    scenes["path"] = {
        "title": f"Tu camino: {localized.get('name')}",
        "voiceover": _path_voiceover(stages, lang),
        "stages": stages,
    }
    script = {
        "path": path_slug,
        "lang": lang,
        **backend_meta,
        "scenes": scenes,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    script_path.write_text(yaml.safe_dump(script, sort_keys=False, allow_unicode=True))
    return {"written": str(script_path)}


# ---------------------------------------------------------------- voz (Piper)

def _ensure_voice(lang: str) -> Path:
    if lang not in VOICES:
        raise VideoError(f"Todavía no hay voz configurada para '{lang}'. Disponibles: {list(VOICES)}")
    VOICE_CACHE.mkdir(parents=True, exist_ok=True)
    onnx_path = VOICE_CACHE / f"{lang}.onnx"
    json_path = VOICE_CACHE / f"{lang}.onnx.json"
    if not onnx_path.exists() or not json_path.exists():
        rel = VOICES[lang]
        for suffix, dest in ((".onnx", onnx_path), (".onnx.json", json_path)):
            with httpx.stream("GET", f"{HF_BASE}/{rel}{suffix}", follow_redirects=True, timeout=120) as response:
                response.raise_for_status()
                with open(dest, "wb") as file:
                    for chunk in response.iter_bytes():
                        file.write(chunk)
    return onnx_path


def _piper_bin() -> str:
    """`piper` vive en el venv (paquete pip), no en el PATH del sistema —
    resolverlo por sys.executable evita fallar en contextos sin el venv
    activado (systemd timer, subprocess en background, etc)."""
    venv_piper = Path(sys.executable).parent / "piper"
    return str(venv_piper) if venv_piper.exists() else "piper"


def _synthesize(text: str, voice_model: Path, audio_path: Path) -> None:
    config = voice_model.with_suffix(".onnx.json")
    result = subprocess.run(
        [_piper_bin(), "-m", str(voice_model), "-c", str(config), "-f", str(audio_path)],
        input=text or ".", capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise VideoError(f"piper falló: {result.stderr.strip()}")


def _wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as wav_file:
        return wav_file.getnframes() / float(wav_file.getframerate())


# ------------------------------------------------------------- slides (Pillow)

_FONT_CACHE: dict[tuple[str, int], ImageFont.FreeTypeFont] = {}


def _font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    key = (str(path), size)
    if key not in _FONT_CACHE:
        _FONT_CACHE[key] = ImageFont.truetype(str(path), size)
    return _FONT_CACHE[key]


def _wrap(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, max_width: int) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        trial = f"{current} {word}".strip()
        if not current or draw.textlength(trial, font=font) <= max_width:
            current = trial
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines or [""]


def _base_slide() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    bar_h = 10
    for x in range(W):
        t = x / W
        draw.line(
            [(x, 0), (x, bar_h)],
            fill=tuple(int(ACCENT[i] + (ACCENT2[i] - ACCENT[i]) * t) for i in range(3)),
        )
    draw.text((70, 40), "Cert Landscape", font=_font(FONT_BOLD, 32), fill=MUTED)
    draw.text((W - 70, H - 56), "study.cybercirujas.club", font=_font(FONT_REGULAR, 26), fill=MUTED, anchor="ra")
    return img, draw


def _slide_title(scene: dict, out_path: Path) -> None:
    img, draw = _base_slide()
    title_font = _font(FONT_BOLD, 84)
    lines = _wrap(draw, scene.get("title", ""), title_font, W - 300)
    total_h = len(lines) * 100
    y = H // 2 - total_h // 2 - 60
    for line in lines:
        w = draw.textlength(line, font=title_font)
        draw.text(((W - w) // 2, y), line, font=title_font, fill=ACCENT)
        y += 100
    sub_font = _font(FONT_REGULAR, 38)
    sub_lines = _wrap(draw, scene.get("voiceover", ""), sub_font, W - 560)[:4]
    y += 30
    for line in sub_lines:
        w = draw.textlength(line, font=sub_font)
        draw.text(((W - w) // 2, y), line, font=sub_font, fill=FG)
        y += 54
    img.save(out_path)


def _slide_bullets(scene: dict, out_path: Path) -> None:
    img, draw = _base_slide()
    draw.text((120, 150), scene.get("title", ""), font=_font(FONT_BOLD, 62), fill=ACCENT)
    bullet_font = _font(FONT_REGULAR, 44)
    y = 320
    for bullet in scene.get("bullets", [])[:5]:
        lines = _wrap(draw, bullet, bullet_font, W - 320)
        draw.rectangle([120, y + 14, 148, y + 42], fill=GOLD)
        for i, line in enumerate(lines):
            draw.text((180, y + i * 56), line, font=bullet_font, fill=FG)
        y += 56 * len(lines) + 38
    img.save(out_path)


def _slide_path(scene: dict, out_path: Path) -> None:
    img, draw = _base_slide()
    draw.text((120, 120), scene.get("title", ""), font=_font(FONT_BOLD, 54), fill=ACCENT)
    stages = scene.get("stages", [])
    n = max(len(stages), 1)
    margin_x = 140
    stage_w = (W - 2 * margin_x) / n
    box_w = min(stage_w - 60, 420)
    center_y = H // 2 + 60
    gap = 22
    pad_top = 20
    line_h = 32
    node_font = _font(FONT_BOLD, 26)
    small_font = _font(FONT_REGULAR, 22)

    # alto de caja variable: cada nombre se banquea a las líneas que necesite
    # (nada se trunca en silencio, ej. "LPIC-3: High Availability and Storage Clusters")
    stage_boxes = []
    for stage in stages:
        boxes = []
        for cert in stage:
            lines = _wrap(draw, cert["name"], node_font, box_w - 36)[:3]
            box_h = pad_top + len(lines) * line_h + (34 if cert.get("validity") else 10)
            boxes.append((cert, lines, box_h))
        stage_boxes.append(boxes)

    for i, boxes in enumerate(stage_boxes):
        cx = margin_x + stage_w * i + stage_w / 2
        total_h = sum(b[2] for b in boxes) + gap * (len(boxes) - 1)
        y = center_y - total_h / 2
        for cert, lines, box_h in boxes:
            draw.rounded_rectangle([cx - box_w / 2, y, cx + box_w / 2, y + box_h], radius=16, outline=ACCENT, width=3)
            ty = y + pad_top
            for line in lines:
                w = draw.textlength(line, font=node_font)
                draw.text((cx - w / 2, ty), line, font=node_font, fill=FG)
                ty += line_h
            validity = cert.get("validity", "")
            if validity:
                w = draw.textlength(validity, font=small_font)
                draw.text((cx - w / 2, y + box_h - 28), validity, font=small_font, fill=GOLD)
            y += box_h + gap
        if i < n - 1:
            x0 = cx + box_w / 2 + 10
            x1 = margin_x + stage_w * (i + 1) + stage_w / 2 - box_w / 2 - 10
            draw.line([(x0, center_y), (x1, center_y)], fill=MUTED, width=3)
            draw.polygon([(x1 - 14, center_y - 10), (x1 - 14, center_y + 10), (x1, center_y)], fill=MUTED)
    img.save(out_path)


def _render_slide(kind: str, scene: dict, out_path: Path) -> None:
    if kind == "title":
        _slide_title(scene, out_path)
    elif kind == "bullets":
        _slide_bullets(scene, out_path)
    elif kind == "path":
        _slide_path(scene, out_path)
    else:
        raise VideoError(f"kind de slide desconocido: {kind}")


# ------------------------------------------------------------------ render

def _mux_scene(image_path: Path, audio_path: Path, out_path: Path) -> None:
    duration = _wav_duration(audio_path) + 0.9
    fade_out_start = max(duration - 0.4, 0)
    subprocess.run(
        [
            "ffmpeg", "-y", "-loop", "1", "-framerate", "30", "-i", str(image_path),
            "-i", str(audio_path),
            "-t", f"{duration:.3f}",
            "-vf", f"fade=t=in:st=0:d=0.25,fade=t=out:st={fade_out_start:.3f}:d=0.4,format=yuv420p",
            # esta build de ffmpeg no trae libx264 (solo encoders de hw + openh264)
            "-c:v", "libopenh264", "-b:v", "3M",
            "-c:a", "aac", "-b:a", "160k",
            str(out_path),
        ],
        check=True, capture_output=True, text=True,
    )


def _concat(clips: list[Path], out_path: Path) -> None:
    list_file = out_path.parent / "concat.txt"
    list_file.write_text("\n".join(f"file '{clip.resolve()}'" for clip in clips))
    subprocess.run(
        ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(list_file), "-c", "copy", str(out_path)],
        check=True, capture_output=True, text=True,
    )
    list_file.unlink()


def render_video(
    path_slug: str,
    lang: str = certs.DEFAULT_LANG,
    force: bool = False,
) -> dict:
    out_dir = media_dir(path_slug, lang)
    script_path = out_dir / "script.yaml"
    if not script_path.exists():
        raise VideoError(
            f"No existe {script_path}. Correr antes: teach paths video-script {path_slug} --lang {lang}"
        )
    video_path = out_dir / "video.mp4"
    if video_path.exists() and not force:
        return {"skipped": f"{video_path} ya existe (usar --force)"}

    script = yaml.safe_load(script_path.read_text())
    scenes = script["scenes"]
    voice_model = _ensure_voice(lang)

    work_dir = out_dir / ".build"
    work_dir.mkdir(parents=True, exist_ok=True)
    clips = []
    try:
        for i, spec in enumerate(SCENES):
            scene = scenes[spec["id"]]
            image_path = work_dir / f"{i:02d}_{spec['id']}.png"
            audio_path = work_dir / f"{i:02d}_{spec['id']}.wav"
            clip_path = work_dir / f"{i:02d}_{spec['id']}.mp4"
            _render_slide(spec["kind"], scene, image_path)
            _synthesize(scene.get("voiceover", ""), voice_model, audio_path)
            _mux_scene(image_path, audio_path, clip_path)
            clips.append(clip_path)

        _concat(clips, video_path)
        thumbnail = out_dir / "thumbnail.png"
        Image.open(work_dir / "00_hook.png").save(thumbnail)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    return {"video": str(video_path), "thumbnail": str(out_dir / "thumbnail.png"), "scenes": len(clips)}
