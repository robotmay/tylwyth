defmodule Tylwyth.Sweeper do
  @moduledoc """
  Periodic private-network, EPMD, and application-supplied BEAM cluster discovery worker.
  Typically supervised via `{Tylwyth, opts}` rather than started directly.
  """

  use GenServer

  alias Tylwyth.Network

  @default_interval_ms 15_000

  @doc """
  Starts the cluster discovery `GenServer`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:tylwyth, :interval, @default_interval_ms)
      end)

    enabled? =
      Keyword.get_lazy(opts, :enabled, fn ->
        parse_env_bool(
          "CLUSTER_AUTODISCOVERY",
          Application.get_env(:tylwyth, :enabled, true)
        )
      end)

    state = %{
      interval: interval,
      enabled?: enabled?,
      sweep_opts: build_sweep_opts(opts)
    }

    if enabled? and Node.alive?() do
      send(self(), :sweep)
    end

    if enabled? do
      schedule_sweep(interval)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    results = Tylwyth.perform_sweep(state.sweep_opts)
    {:reply, results, state}
  end

  def handle_call({:sweep_subnet, cidr}, _from, state) do
    results =
      state.sweep_opts
      |> Keyword.put(:override_cidr, cidr)
      |> Tylwyth.perform_sweep()

    {:reply, results, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    if state.enabled? and Node.alive?() do
      Tylwyth.perform_sweep(state.sweep_opts)
    end

    if state.enabled? do
      schedule_sweep(state.interval)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp build_sweep_opts(opts) do
    basename =
      Keyword.get_lazy(opts, :basename, fn ->
        System.get_env("NODE_BASENAME") ||
          Application.get_env(:tylwyth, :basename) ||
          infer_basename_from_node()
      end)

    subnet =
      Keyword.get_lazy(opts, :subnet, fn ->
        Application.get_env(:tylwyth, :subnet)
      end)

    static_nodes =
      opts
      |> Keyword.get(:static_nodes)
      |> Kernel.||(Application.get_env(:tylwyth, :static_nodes, []))
      |> Network.parse_node_list()

    [
      basename: basename,
      subnet: subnet,
      static_nodes: static_nodes,
      extra_nodes: Keyword.get(opts, :extra_nodes),
      on_connect: Keyword.get(opts, :on_connect),
      max_concurrency: Keyword.get(opts, :max_concurrency, 50),
      timeout: Keyword.get(opts, :timeout, 10_000)
    ]
  end

  defp infer_basename_from_node do
    case String.split(to_string(node()), "@") do
      [name, _host] when name != "" and name != "nonode" -> name
      _ -> "app"
    end
  end

  defp parse_env_bool(env_var, default) do
    case System.get_env(env_var) do
      nil ->
        default

      raw ->
        normalized = raw |> String.trim() |> String.downcase()

        cond do
          normalized in ~w(false 0 no) -> false
          normalized in ~w(true 1 yes) -> true
          true -> default
        end
    end
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
