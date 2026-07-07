"""CLI de la plataforma. Llama a core directo (archivos locales, sin API)."""

import typer

from .core import catalog, certs, generator, labs

app = typer.Typer(help="Plataforma educativa self-service", no_args_is_help=True)
cert_app = typer.Typer(help="Certificaciones del catálogo", no_args_is_help=True)
lab_app = typer.Typer(help="Labs por tema", no_args_is_help=True)
app.add_typer(cert_app, name="cert")
app.add_typer(lab_app, name="lab")


@cert_app.command("list")
def cert_list() -> None:
    """Lista las certificaciones del catálogo."""
    entries = catalog.list_certs()
    if not entries:
        typer.echo("Catálogo vacío. Agregar con: teach cert add")
        return
    for cert_id, entry in entries.items():
        typer.echo(
            f"{cert_id:20} {entry.get('name', ''):30} "
            f"v{entry.get('tracked_version', '?'):6} {entry.get('upstream_status', '')}"
        )


@cert_app.command("show")
def cert_show(cert_id: str) -> None:
    """Muestra el temario y estado de cada tema."""
    entry = catalog.get_cert(cert_id)
    typer.echo(f"{entry['name']} (examen {entry['exam']}, v{entry['tracked_version']})\n")
    for topic in certs.topics(cert_id):
        typer.echo(
            f"  {topic['id']:5} [{topic.get('status', 'pending'):9}] "
            f"peso {topic.get('weight', '?')}  {topic['title']}"
        )


@cert_app.command("add")
def cert_add(
    cert_id: str,
    name: str = typer.Option(..., "--name", help="Nombre de la certificación"),
    exam: str = typer.Option("", "--exam", help="Código de examen"),
    objectives: str = typer.Option("", "--objectives", help="URL de objetivos oficiales"),
    category: str = typer.Option("general", "--category", help="Categoría (ej. linux, cloud-native)"),
) -> None:
    """Agrega una cert al catálogo y crea el MD template del temario."""
    catalog.add_cert(cert_id, name, exam, objectives, category)
    path = certs.scaffold(cert_id, name, exam)
    typer.echo(f"Creado {path}. Completar los topics y correr: teach cert generate {cert_id}")


@cert_app.command("generate")
def cert_generate(
    cert_id: str,
    topic: str = typer.Option(None, "--topic", help="Generar solo este tema (ej. 1.1)"),
    force: bool = typer.Option(False, "--force", help="Regenerar aunque esté generated/edited"),
    backend: str = typer.Option(
        None, "--backend", help="litellm | claude | codex | gemini | custom (default: $TEACH_BACKEND o litellm)"
    ),
) -> None:
    """Genera contenido con AI para los temas pending/stale."""
    try:
        if topic:
            results = [generator.generate_topic(cert_id, topic, force=force, backend=backend)]
        else:
            results = generator.generate_cert(cert_id, force=force, backend=backend)
    except generator.GeneratorConfigError as error:
        typer.echo(f"Error de configuración: {error}", err=True)
        raise typer.Exit(1)
    for result in results:
        if "skipped" in result:
            typer.echo(f"  {result['topic']}: salteado — {result['skipped']}")
        else:
            typer.echo(f"  {result['topic']}: generado en {result['written']}")


@lab_app.command("up")
def lab_up(cert_id: str, topic_id: str) -> None:
    """Levanta el lab de un tema (terraform)."""
    try:
        result = labs.up(cert_id, topic_id)
    except labs.LabError as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"Lab {cert_id}/{topic_id}: {result['state']}")


@lab_app.command("down")
def lab_down(cert_id: str, topic_id: str) -> None:
    """Destruye el lab de un tema."""
    try:
        result = labs.down(cert_id, topic_id)
    except labs.LabError as error:
        typer.echo(f"Error: {error}", err=True)
        raise typer.Exit(1)
    typer.echo(f"Lab {cert_id}/{topic_id}: {result['state']}")


@lab_app.command("status")
def lab_status(cert_id: str, topic_id: str) -> None:
    """Estado del lab de un tema."""
    result = labs.status(cert_id, topic_id)
    typer.echo(f"Lab {cert_id}/{topic_id}: {result.get('state')}")


@app.command()
def serve(
    host: str = typer.Option("127.0.0.1", "--host"),
    port: int = typer.Option(8000, "--port"),
) -> None:
    """Levanta la API + web sobre el mismo catálogo."""
    import uvicorn

    uvicorn.run("teach.api:app", host=host, port=port)


def main() -> None:
    app()
