defmodule Tylwyth do
  @moduledoc """
  Shared private-network (`/24`), local EPMD, and pluggable BEAM peer discovery library.

  Add `{Tylwyth, opts}` directly under an application or cluster supervisor:

      children = [
        {Tylwyth,
         basename: "my_app",
         extra_nodes: &MyApp.Cluster.extra_nodes/0,
         on_connect: fn peer -> MyApp.Cluster.sync_peer(peer) end}
      ]
  """

  require Logger

  alias Tylwyth.{Network, Sweeper}

  @type sweep_result ::
          {:connected, node()}
          | {:unreachable, node()}
          | {:error, :timeout}

  @doc """
  Child specification delegating supervision to `Tylwyth.Sweeper`.
  """
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, Sweeper),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Starts the `Tylwyth.Sweeper` process.
  """
  def start_link(opts \\ []) do
    Sweeper.start_link(opts)
  end

  @doc """
  Triggers a synchronous discovery sweep on the running `Tylwyth.Sweeper`.
  """
  @spec sweep(GenServer.server()) :: [sweep_result()]
  def sweep(server \\ Sweeper) do
    GenServer.call(server, :sweep, 30_000)
  end

  @doc """
  Triggers a synchronous discovery sweep targeting a specific `cidr` subnet.
  """
  @spec sweep_subnet(String.t(), GenServer.server()) :: [sweep_result()]
  def sweep_subnet(cidr, server \\ Sweeper) when is_binary(cidr) and cidr != "" do
    GenServer.call(server, {:sweep_subnet, cidr}, 30_000)
  end

  @doc """
  Runs a discovery sweep immediately using `opts` without requiring a running sweeper process.
  """
  @spec perform_sweep(keyword()) :: [sweep_result()]
  def perform_sweep(opts \\ []) do
    if not Node.alive?() do
      []
    else
      do_perform_sweep(opts)
    end
  end

  @doc """
  Pings a specific BEAM node name (binary or atom) and runs `:on_connect` if reachable.
  """
  @spec connect_node(String.t() | node(), keyword()) ::
          {:ok, node()} | {:error, :invalid_node_name | :unreachable}
  def connect_node(node_or_str, opts \\ [])

  def connect_node(node_atom, opts) when is_atom(node_atom) do
    connect_node(Atom.to_string(node_atom), opts)
  end

  def connect_node(node_str, opts) when is_binary(node_str) do
    trimmed = String.trim(node_str)

    if Network.valid_node_name?(trimmed) do
      target = String.to_atom(trimmed)

      case Node.ping(target) do
        :pong ->
          invoke_on_connect(Keyword.get(opts, :on_connect), target)
          {:ok, target}

        :pang ->
          {:error, :unreachable}
      end
    else
      {:error, :invalid_node_name}
    end
  end

  @doc """
  Returns currently connected peer nodes.
  """
  @spec connected_nodes() :: [node()]
  def connected_nodes, do: Node.list()

  @doc """
  Returns a normalized summary map of local node distribution and private network info.
  """
  @spec cluster_info() :: map()
  def cluster_info do
    connected = Node.list()
    distributed? = Node.alive?()

    %{
      self: node(),
      connected_nodes: connected,
      node_count: length(connected) + 1,
      distributed?: distributed?,
      is_distributed: distributed?,
      private_ip: local_private_ip()
    }
  end

  @doc """
  Returns the node's private host IP if distributed on an IP, otherwise detects it from NICs.
  """
  @spec local_private_ip() :: String.t() | nil
  def local_private_ip do
    case String.split(to_string(node()), "@") do
      [_, host] ->
        if Network.valid_ip?(host), do: host, else: Network.detect_private_ip()

      _ ->
        Network.detect_private_ip()
    end
  end

  @doc """
  Discovers co-located BEAM nodes registered in local EPMD (for same-host rolling handovers).

  Returns `[]` when EPMD-less static distribution is active (`ERL_DIST_STATIC_PORT`,
  `-start_epmd false`, or `-erl_epmd_port`), because querying `:erl_epmd.names/1` in that
  mode dials the node's own Erlang distribution listener instead of an EPMD daemon.
  """
  @spec local_epmd_nodes() :: [node()]
  def local_epmd_nodes do
    if static_epmd_disabled?() do
      []
    else
      do_local_epmd_nodes()
    end
  end

  defp do_local_epmd_nodes do
    host_parts =
      case String.split(to_string(node()), "@") do
        [_, host] -> [host]
        _ -> []
      end

    detected_ip = local_private_ip()

    valid_hosts =
      case host_parts do
        ["127.0.0.1"] -> ["127.0.0.1"]
        [h] -> Enum.uniq(Enum.reject([h, detected_ip], &is_nil/1))
        [] -> Enum.uniq(Enum.reject([detected_ip, "127.0.0.1"], &is_nil/1))
      end

    epmd_ips = Enum.uniq(Enum.reject(["127.0.0.1", detected_ip], &is_nil/1))

    discovered_names =
      epmd_ips
      |> Enum.flat_map(fn ip_str ->
        case :erl_epmd.names(to_charlist(ip_str)) do
          {:ok, names} -> names
          _ -> []
        end
      end)
      |> Enum.uniq_by(fn {name, _port} -> name end)

    for {name_cl, _port} <- discovered_names,
        host <- valid_hosts,
        candidate = "#{to_string(name_cl)}@#{host}",
        Network.valid_node_name?(candidate) do
      String.to_atom(candidate)
    end
    |> Enum.reject(&(&1 == node()))
    |> Enum.uniq()
  rescue
    _ -> []
  end

  defp static_epmd_disabled? do
    static_port_env? =
      case System.get_env("ERL_DIST_STATIC_PORT") do
        val when is_binary(val) -> String.trim(val) != ""
        _ -> false
      end

    start_epmd_false? =
      case :init.get_argument(:start_epmd) do
        {:ok, args} -> List.flatten(args) == ~c"false"
        _ -> false
      end

    erl_epmd_port_flag? =
      case :init.get_argument(:erl_epmd_port) do
        {:ok, [[_ | _] | _]} -> true
        _ -> false
      end

    static_port_env? or start_epmd_false? or erl_epmd_port_flag?
  end

  # --- Private Sweep Helpers ---

  defp do_perform_sweep(opts) do
    basename = Keyword.get(opts, :basename) || "app"
    override_cidr = Keyword.get(opts, :override_cidr)
    subnet_cidr = override_cidr || resolve_subnet(Keyword.get(opts, :subnet))
    connected = Node.list()

    static_nodes = resolve_static_nodes(Keyword.get(opts, :static_nodes, []))
    epmd_nodes = local_epmd_nodes()
    extra_nodes = invoke_extra_nodes(Keyword.get(opts, :extra_nodes))

    candidate_nodes =
      if (connected == [] or is_binary(override_cidr)) and is_binary(subnet_cidr) do
        Network.generate_subnet_nodes(subnet_cidr, basename)
      else
        []
      end

    all_targets =
      (Enum.uniq(static_nodes ++ epmd_nodes ++ extra_nodes ++ candidate_nodes) -- [node()]) --
        connected

    ping_targets(all_targets, opts)
  end

  defp ping_targets([], _opts), do: []

  defp ping_targets(all_targets, opts) do
    on_connect = Keyword.get(opts, :on_connect)
    max_concurrency = Keyword.get(opts, :max_concurrency, 50)
    timeout = Keyword.get(opts, :timeout, 10_000)

    all_targets
    |> Task.async_stream(
      fn target_node ->
        case Node.ping(target_node) do
          :pong ->
            Logger.info("[Tylwyth] Discovered peer node: #{target_node}")
            invoke_on_connect(on_connect, target_node)
            {:connected, target_node}

          :pang ->
            {:unreachable, target_node}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, res} -> res
      _ -> {:error, :timeout}
    end)
  end

  defp resolve_subnet(configured_subnet) do
    case System.get_env("CLUSTER_SUBNET") do
      cidr when is_binary(cidr) and cidr != "" ->
        cidr

      _ ->
        if is_binary(configured_subnet) and configured_subnet != "" do
          configured_subnet
        else
          Network.detect_private_subnet()
        end
    end
  end

  defp resolve_static_nodes(configured_static) do
    env_nodes = Network.parse_node_list(System.get_env("CLUSTER_STATIC_NODES"))
    app_nodes = Network.parse_node_list(configured_static)
    Enum.uniq(env_nodes ++ app_nodes)
  end

  defp invoke_extra_nodes(fun) when is_function(fun, 0) do
    fun.() |> Network.parse_node_list()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp invoke_extra_nodes(_), do: []

  defp invoke_on_connect(fun, target_node) when is_function(fun, 1) do
    fun.(target_node)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp invoke_on_connect(_, _), do: :ok
end
