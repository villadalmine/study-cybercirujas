"""Platform CLI. Calls core directly (local files, no API)."""

import typer

from .core import catalog, certs, generator, labs

app = typer.Typer(help="Self-service education platform", no_args_is_help=True)
cert_app = typer.Typer(help="Catalog certifications", no_args_is_help=True)
lab_app = typer.Typer(help="Per-topic labs", no_args_is_help=True)
tracker_app = typer.Typer(help="Official-source scraper (nothing is static)", no_args_is_help=True)
paths_app = typer.Typer(help="Career paths", no_args_is_help=True)
app.add_typer(cert_app, name="cert")
app.add_typer(lab_app, name="lab")
app.add_typer(tracker_app, name="tracker")
app.add_typer(paths_app, name="paths")


@cert_app.command("list")
def cert_list() -> None:
    """List the certifications in the catalog."""
    entries = catalog.list_certs()
    if not entries:
        typer.echo("Empty catalog. Add one with: teach cert add")
        return
    for cert_id, entry in entries.items():
        typer.echo(
            f"{cert_id:20} {entry.get('name', ''):30} "
            f"v{entry.get('tracked_version', '?'):6} {entry.get('upstream_status', '')}"
        )


@cert_app.command("show")
def cert_show(cert_id: str) -> None:
    """Show the syllabus and the status of each topic."""
    entry = catalog.get_cert(cert_id)
    typer.echo(f"{entry['name']} (exam {entry['exam']}, v{entry['tracked_version']})\n")
    for topic in certs.topics(cert_id):
        typer.echo(
            f"  {topic['id']:5} [{topic.get('status', 'pending'):9}] "
            f"weight {topic.get('weight', '?')}  {topic['title']}"
        )


@cert_app.command("add")
def cert_add(
    cert_id: str,
    name: str = typer.Option(..., "--name", help="Certification name"),
    exam: str = typer.Option("", "--exam", help="Exam code"),
    objectives: str = typer.Option("", "--objectives", help="URL of the official objectives"),
    category: str = typer.Option("general", "--category", help="Category (e.g. linux, cloud-native)"),
) -> None:
    """Add a cert to the catalog and create the syllabus MD template."""
    catalog.add_cert(cert_id, name, exam, objectives, category)
    path = certs.scaffold(cert_id, name, exam)
    typer.echo(f"Created {path}. Fill in the topics and run: teach cert generate {cert_id}")


@cert_app.command("generate")
def cert_generate(
    cert_id: str,
    topic: str = typer.Option(None, "--topic", help="Generate only this topic (e.g. 1.1)"),
    force: bool = typer.Option(False, "--force", help="Regenerate even when generated/edited"),
    backend: str = typer.Option(
        None, "--backend", help="litellm | claude | codex | gemini | custom (default: $TEACH_BACKEND or litellm)"
    ),
    lang: str = typer.Option("es", "--lang", help="es | en | fr | de | zh | ja | pt"),
) -> None:
    """Generate content with AI for pending/stale topics."""
    try:
        if topic:
            results = [generator.generate_topic(cert_id, topic, force=force, backend=backend, lang=lang)]
        else:
            results = generator.generate_cert(cert_id, force=force, backend=backend, lang=lang)
    except generator.GeneratorConfigError as error:
        typer.echo(f"Configuration error: {error}", err=True)
        raise typer.Exit(1)
    for result in results:
        if "skipped" in result:
            typer.echo(f"  {result['topic']}: skipped — {result['skipped']}")
        else:
            typer.echo(f"  {result['topic']}: generated in {result['written']}")


@lab_app.command("up")
def lab_up(cert_id: str, topic_id: str) -> None:
    """Bring up a topic lab (local Docker, or terraform if lab.yaml asks for it)."""
    try:
        result = labs.up(cert_id, topic_id)
    except labs.LabError as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"Lab {cert_id}/{topic_id}: {result['state']}")


@lab_app.command("down")
def lab_down(cert_id: str, topic_id: str) -> None:
    """Tear down a topic lab."""
    try:
        result = labs.down(cert_id, topic_id)
    except labs.LabError as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"Lab {cert_id}/{topic_id}: {result['state']}")


@lab_app.command("status")
def lab_status(cert_id: str, topic_id: str) -> None:
    """Status of a topic lab."""
    result = labs.status(cert_id, topic_id)
    typer.echo(f"Lab {cert_id}/{topic_id}: {result.get('state')}")


@tracker_app.command("sync")
def tracker_sync(
    provider: str = typer.Option("all", "--provider", help="all | cncf | lpi"),
    backend: str = typer.Option(None, "--backend", help="AI backend used to parse pages"),
) -> None:
    """Scrape the official sources and update the catalog."""
    from .core import tracker

    try:
        changes = []
        if provider in ("all", "cncf"):
            changes += tracker.sync_cncf()
        if provider in ("all", "lpi"):
            changes += tracker.sync_lpi(backend=backend)
    except Exception as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    for change in changes:
        typer.echo(f"  {change}")


@cert_app.command("snapshot")
def cert_snapshot(
    cert_id: str,
    backend: str = typer.Option(None, "--backend"),
    force: bool = typer.Option(False, "--force", help="Re-snapshot even if a syllabus exists"),
) -> None:
    """Freeze the official syllabus (HTML/PDF -> AI -> topics in the MD)."""
    from .core import tracker

    try:
        result = tracker.snapshot_topics(cert_id, backend=backend, force=force)
    except Exception as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"  {result['cert']}: {result['topics']} topics frozen (v{result['version']})")
    if result.get("added"):
        typer.echo(f"  added: {', '.join(result['added'])}")
    if result.get("stale"):
        typer.echo(
            f"  stale ({len(result['stale'])}): {', '.join(result['stale'])}\n"
            f"  -> the syllabus changed; regenerate with 'teach cert generate {result['cert']} "
            f"--lang <language>' for every language that has content."
        )
    if result.get("edited_changed"):
        typer.echo(
            f"  hand-edited topics whose syllabus entry changed: "
            f"{', '.join(result['edited_changed'])}\n"
            f"  -> not touched automatically; review and regenerate with --force if appropriate."
        )


@cert_app.command("video-script")
def cert_video_script(
    cert_id: str,
    backend: str = typer.Option(None, "--backend"),
    lang: str = typer.Option("es", "--lang"),
    force: bool = typer.Option(False, "--force"),
) -> None:
    """The AI writes the video script for a single certification (frozen into script.yaml)."""
    from .core import video

    try:
        result = video.generate_cert_script(cert_id, backend=backend, lang=lang, force=force)
    except Exception as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"  {result}")


@cert_app.command("video")
def cert_video(
    cert_id: str,
    lang: str = typer.Option("es", "--lang"),
    force: bool = typer.Option(False, "--force"),
) -> None:
    """Render a certification video (slides + Piper voice + ffmpeg)."""
    from .core import video

    try:
        result = video.render_cert_video(cert_id, lang=lang, force=force)
    except Exception as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"  {result}")


@paths_app.command("generate")
def paths_generate(
    backend: str = typer.Option(None, "--backend"),
) -> None:
    """The AI proposes career paths from the catalog (edited is never overwritten)."""
    from .core import tracker

    try:
        changes = tracker.generate_paths(backend=backend)
    except Exception as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    for change in changes:
        typer.echo(f"  {change}")


@paths_app.command("translate")
def paths_translate(
    backend: str = typer.Option(None, "--backend"),
    lang: str = typer.Option(None, "--lang", help="un idioma (ej. en); omitir = todos"),
) -> None:
    """Translate path texts into the supported languages."""
    from .core import tracker

    try:
        changes = tracker.translate_paths(backend=backend, langs=[lang] if lang else None)
    except Exception as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    for change in changes:
        typer.echo(f"  {change}")


@paths_app.command("video-script")
def paths_video_script(
    path_slug: str,
    backend: str = typer.Option(None, "--backend"),
    lang: str = typer.Option("es", "--lang"),
    force: bool = typer.Option(False, "--force"),
) -> None:
    """The AI writes a path's video script (frozen into script.yaml)."""
    from .core import video

    try:
        result = video.generate_script(path_slug, backend=backend, lang=lang, force=force)
    except Exception as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"  {result}")


@paths_app.command("video")
def paths_video(
    path_slug: str,
    lang: str = typer.Option("es", "--lang"),
    force: bool = typer.Option(False, "--force"),
) -> None:
    """Render the video (slides + Piper voice + ffmpeg) from script.yaml."""
    from .core import video

    try:
        result = video.render_video(path_slug, lang=lang, force=force)
    except Exception as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"  {result}")


@app.command()
def serve(
    host: str = typer.Option("127.0.0.1", "--host"),
    port: int = typer.Option(8000, "--port"),
) -> None:
    """Serve the API + web over the same catalog."""
    import uvicorn

    uvicorn.run("teach.api:app", host=host, port=port)


def main() -> None:
    app()
