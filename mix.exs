defmodule ExZvec.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/thedonmon/ex_zvec"

  def project do
    [
      app: :ex_zvec,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      docs: docs(),
      compilers: Mix.compilers(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.37", runtime: false},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "ex_zvec",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(
        lib native/ex_zvec/src native/ex_zvec/cpp
        native/ex_zvec/Cargo.toml native/ex_zvec/build.rs
        mix.exs LICENSE
      )
    ]
  end

  defp description do
    """
    Elixir bindings for zvec — Alibaba's embedded C++ vector database.
    Provides in-process vector similarity search via Rustler NIFs with
    optional filtered search, scope isolation, and BM25 text fallback.
    """
  end

  defp docs do
    [
      main: "ExZvec",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp aliases do
    []
  end
end
