defmodule Tylwyth.MixProject do
  use Mix.Project

  @version "0.1.3"

  def project do
    [
      app: :tylwyth,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "format --check-formatted", "test"]
    ]
  end
end
