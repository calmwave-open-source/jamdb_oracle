defmodule Ecto.Adapters.Jamdb.Oracle do
  @moduledoc """
  Adapter module for Oracle. `Ecto.Adapters.SQL` callbacks implementation.

  It uses `jamdb_oracle` for communicating to the database.

  """

  use Ecto.Adapters.SQL, driver: Jamdb.Oracle, migration_lock: nil

  # Allow us to use this in tests
  @behaviour Ecto.Adapter.Storage

  ### storage implementation

  @impl true
  def storage_up(opts) do
    with {:ok, tables} <- count_tables(opts),
         {:ok, objects} <- count_objects(opts) do
      if objects > 0 or tables > 0 do
        {:error, :already_up}
      else
        ## Nothing to do since we're not actually destroying "DATABASES" in the oracle driver
        :ok
      end
    else
      {:error, _} = err ->
        err
    end
  end

  @impl true
  def storage_down(opts) do
    with {:ok, tables} <- count_tables(opts),
         {:ok, objects} <- count_objects(opts) do
      if objects == 0 and tables == 0 do
        {:error, :already_down}
      else
        ## delete everything in the current tablespace that this user has access to
        ## DO NOT RUN `ecto.drop` with SYSADMIN user - this will delete everything in all databases/tablespaces
        with :ok <- delete_tables(opts),
             :ok <- delete_objects(opts) do
          :ok
        else
          {:error, _} = err ->
            err
        end
      end
    else
      {:error, _} = err ->
        err
    end
  end

  @impl true
  def storage_status(opts) do
    with {:ok, tables} <- count_tables(opts),
         {:ok, objects} <- count_objects(opts) do
      if objects == 0 and tables == 0 do
        :down
      else
        :up
      end
    else
      {:error, _} = err ->
        err
    end
  end

  defp count_tables(opts) do
    count_items("SELECT \"TABLE_NAME\" FROM user_tables", opts)
  end

  defp count_objects(opts) do
    count_items(
      "SELECT \"OBJECT_NAME\" FROM user_objects WHERE object_type IN ('VIEW','PACKAGE','SEQUENCE', 'PROCEDURE', 'FUNCTION', 'INDEX')",
      opts
    )
  end

  defp count_items(fetch_query, opts) do
    case run_query(fetch_query, opts) do
      {:ok, %{num_rows: rows}} ->
        {:ok, rows}

      {:error, error} ->
        {:error, Exception.message(error)}

      other ->
        {:error, other}
    end
  end

  defp delete_tables(opts) do
    delete_items(
      "SELECT 'DROP TABLE '||table_name||' CASCADE CONSTRAINTS' from user_tables",
      opts
    )
  end

  defp delete_objects(opts) do
    delete_items(
      "SELECT 'DROP '||object_type||' '|| object_name FROM user_objects WHERE object_type in ('VIEW','PACKAGE','SEQUENCE', 'PROCEDURE', 'FUNCTION', 'INDEX')",
      opts
    )
  end

  defp delete_items(fetch_query, opts) do
    case run_query(fetch_query, opts) do
      {:ok, %{rows: rows}} ->
        rows
        |> List.flatten()
        |> run_drop_commands(opts)

      {:error, error} ->
        {:error, Exception.message(error)}

      other ->
        {:error, other}
    end
  end

  defp run_drop_commands(commands, opts) do
    # keep "accumulating" :ok, unless an error happens and then halt the operations
    # unfortunately OracleDB does not support transactions while doing schema changes
    # so this can result in partial deletes
    Enum.reduce_while(commands, :ok, fn drop_command, ok ->
      case run_query(drop_command, opts) do
        {:ok, %{rows: [[]], num_rows: 1}} ->
          {:cont, ok}

        {:error, error} ->
          {:halt, {:error, Exception.message(error)}}

        other ->
          {:halt, {:error, other}}
      end
    end)
  end

  ### adapter implementation

  @impl true
  def ensure_all_started(config, type) do
    Ecto.Adapters.SQL.ensure_all_started(:jamdb_oracle, config, type)
  end

  @impl true
  def loaders({:array, _}, type), do: [&array_decode/1, type]
  def loaders({:embed, _}, type), do: [&json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
  def loaders({:map, _}, type), do: [&json_decode/1, &Ecto.Type.embedded_load(type, &1, :json)]
  def loaders(:map, type), do: [&json_decode/1, type]
  def loaders(:float, type), do: [&float_decode/1, type]
  def loaders(:boolean, type), do: [&bool_decode/1, type]
  def loaders(:binary_id, type), do: [Ecto.UUID, type]
  def loaders(_, type), do: [type]

  @impl true
  def dumpers({:map, _}, type), do: [&Ecto.Type.embedded_dump(type, &1, :json)]
  def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  def dumpers(_, type), do: [type]

  defp bool_decode("0"), do: {:ok, false}
  defp bool_decode("1"), do: {:ok, true}
  defp bool_decode(0), do: {:ok, false}
  defp bool_decode(1), do: {:ok, true}
  defp bool_decode(x), do: {:ok, x}

  defp float_decode(%Decimal{} = decimal), do: {:ok, Decimal.to_float(decimal)}
  defp float_decode(x), do: {:ok, x}

  defp json_decode(x) when is_binary(x), do: {:ok, Jamdb.Oracle.json_library().decode!(x)}
  defp json_decode(x), do: {:ok, x}

  defp array_decode(x) when is_binary(x), do: {:ok, Jamdb.Oracle.to_list(x)}
  defp array_decode(x), do: {:ok, x}

  @impl true
  def lock_for_migrations(_meta, _opts, fun), do: fun.()

  @impl true
  def supports_ddl_transaction? do
    false
  end

  ## Helpers
  ## From https://raw.githubusercontent.com/elixir-ecto/ecto_sql/refs/heads/master/lib/ecto/adapters/postgres.ex
  defp run_query(sql, opts) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:jamdb_oracle)

    opts =
      opts
      |> Keyword.drop([:name, :log, :pool, :pool_size])
      |> Keyword.put(:backoff_type, :stop)
      |> Keyword.put(:max_restarts, 0)

    task =
      Task.Supervisor.async_nolink(Ecto.Adapters.SQL.StorageSupervisor, fn ->
        {:ok, conn} = Jamdb.Oracle.start_link(opts)

        value = Ecto.Adapters.Jamdb.Oracle.Connection.query(conn, sql, [], opts)
        GenServer.stop(conn)
        value
      end)

    timeout = Keyword.get(opts, :timeout, 15_000)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, error}} ->
        {:error, error}

      {:exit, {%{__struct__: struct} = error, _}}
      when struct in [DBConnection.Error] ->
        {:error, error}

      {:exit, reason} ->
        {:error, RuntimeError.exception(Exception.format_exit(reason))}

      nil ->
        {:error, RuntimeError.exception("command timed out")}
    end
  end
end
