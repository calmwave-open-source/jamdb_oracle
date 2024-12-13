defmodule Jamdb.Oracle.Mixfile do
  use Mix.Project

  def project do
    [
      app: :jamdb_oracle,
      version: "0.5.11",
      elixir: "~> 1.11",
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :public_key, :xssl]
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:xssl,
       github: "calmwave-open-source/xssl", ref: "390b8b933a466bb86ee13f89f3db72abd7e9308d"}
    ]
  end

  defp description do
    "Erlang driver and Ecto adapter for Oracle"
  end

  defp package do
    [
      files: ["src", "include", "lib", "mix.exs"],
      maintainers: ["Mykhailo Vstavskyi", "Sergiy Kostyushkin"],
      licenses: ["MIT"],
      links: %{"Github" => "https://github.com/erlangbureau/jamdb_oracle"}
    ]
  end
end
