defmodule Tylwyth.Network do
  @moduledoc """
  Private-network IPv4/subnet inspection and BEAM node target generation.
  Excludes common Docker bridge subnets (`172.17.x`, `172.18.x`, `172.20.x`) when
  scanning interfaces so private LAN/overlay NICs (e.g. `10.0.0.0/24`) are chosen.
  """

  @docker_bridge_second_octets [17, 18, 20]
  @node_basename_regex ~r/^[A-Za-z0-9_-]{1,64}$/
  @node_host_regex ~r/^[A-Za-z0-9._:-]{1,253}$/

  @doc """
  Returns `true` if `str` parses as a valid IPv4 or IPv6 address.
  """
  @spec valid_ip?(term()) :: boolean()
  def valid_ip?(str) when is_binary(str) do
    match?({:ok, _}, :inet.parse_address(to_charlist(str)))
  end

  def valid_ip?(_), do: false

  @doc """
  Returns `true` if `str` is a well-formed BEAM node name (`basename@host`).
  """
  @spec valid_node_name?(term()) :: boolean()
  def valid_node_name?(str) when is_binary(str) and byte_size(str) <= 320 do
    case String.split(str, "@") do
      [basename, host] when host != "" ->
        Regex.match?(@node_basename_regex, basename) and
          (valid_ip?(host) or
             (Regex.match?(@node_host_regex, host) and not String.starts_with?(host, ".") and
                not String.ends_with?(host, ".")))

      _ ->
        false
    end
  end

  def valid_node_name?(_), do: false

  @doc """
  Detects the first RFC1918 private IPv4 address from local network interfaces.
  """
  @spec detect_private_ip() :: String.t() | nil
  def detect_private_ip do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} -> detect_private_ip_from_ifaddrs(ifaddrs)
      _ -> nil
    end
  end

  @doc """
  Pure helper selecting the first RFC1918 private IPv4 string from `:inet.getifaddrs/0` entries.
  """
  @spec detect_private_ip_from_ifaddrs([{charlist(), keyword()}]) :: String.t() | nil
  def detect_private_ip_from_ifaddrs(ifaddrs) when is_list(ifaddrs) do
    first_private_ipv4(ifaddrs, fn {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}" end)
  end

  @doc """
  Detects the `/24` CIDR subnet containing the first non-Docker RFC1918 interface.
  """
  @spec detect_private_subnet() :: String.t() | nil
  def detect_private_subnet do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} -> detect_private_subnet_from_ifaddrs(ifaddrs)
      _ -> nil
    end
  end

  @doc """
  Pure helper deriving a `/24` CIDR subnet string from `:inet.getifaddrs/0` entries.
  """
  @spec detect_private_subnet_from_ifaddrs([{charlist(), keyword()}]) :: String.t() | nil
  def detect_private_subnet_from_ifaddrs(ifaddrs) when is_list(ifaddrs) do
    first_private_ipv4(ifaddrs, fn {a, b, c, _d} -> "#{a}.#{b}.#{c}.0/24" end)
  end

  @doc """
  Expands a private/loopback CIDR (`/24` or `/16`) or IP prefix (`"10.0.0"` / `"10.0.0.1"`)
  into BEAM node atoms. Rejects public subnets and invalid octets or basenames.
  """
  @spec generate_subnet_nodes(String.t() | nil, String.t()) :: [node()]
  def generate_subnet_nodes(cidr, basename) when is_binary(cidr) and is_binary(basename) do
    if Regex.match?(@node_basename_regex, basename) do
      trimmed = String.trim(cidr)

      case String.split(trimmed, "/") do
        [base, "24"] ->
          expand_24(base, basename)

        [base, "16"] ->
          expand_16(base, basename)

        [base] ->
          expand_24(base, basename)

        _ ->
          []
      end
    else
      []
    end
  end

  def generate_subnet_nodes(_, _), do: []

  @doc """
  Normalizes a comma-separated string or list of node names into valid node atoms.
  """
  @spec parse_node_list(nil | String.t() | [node() | String.t()]) :: [node()]
  def parse_node_list(nil), do: []
  def parse_node_list(""), do: []

  def parse_node_list(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> parse_node_list()
  end

  def parse_node_list(items) when is_list(items) do
    items
    |> Enum.reduce([], fn item, acc ->
      str = item |> to_string() |> String.trim()

      if valid_node_name?(str) do
        [String.to_atom(str) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  def parse_node_list(_), do: []

  # --- Private Helpers ---

  defp first_private_ipv4(ifaddrs, formatter) do
    Enum.find_value(ifaddrs, fn {_name, flags} ->
      case Keyword.get(flags, :addr) do
        tuple when tuple_size(tuple) == 4 ->
          if private_routable_ipv4?(tuple), do: formatter.(tuple), else: nil

        _ ->
          nil
      end
    end)
  end

  defp private_routable_ipv4?({10, _, _, _}), do: true
  defp private_routable_ipv4?({192, 168, _, _}), do: true

  defp private_routable_ipv4?({172, b, _, _})
       when b >= 16 and b <= 31 and b not in @docker_bridge_second_octets,
       do: true

  defp private_routable_ipv4?(_), do: false

  defp private_or_loopback_ipv4?({127, _, _, _}), do: true
  defp private_or_loopback_ipv4?({10, _, _, _}), do: true
  defp private_or_loopback_ipv4?({192, 168, _, _}), do: true
  defp private_or_loopback_ipv4?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_or_loopback_ipv4?(_), do: false

  defp expand_24(base, basename) do
    case parse_ipv4_prefix(base) do
      {:ok, {a, b, c}} ->
        if private_or_loopback_ipv4?({a, b, c, 0}) do
          for d <- 1..254, do: String.to_atom("#{basename}@#{a}.#{b}.#{c}.#{d}")
        else
          []
        end

      :error ->
        []
    end
  end

  defp expand_16(base, basename) do
    case parse_ipv4_quad(base) do
      {:ok, {a, b, _c, _d}} ->
        if private_or_loopback_ipv4?({a, b, 0, 0}) do
          for c <- 0..1, d <- 1..254, do: String.to_atom("#{basename}@#{a}.#{b}.#{c}.#{d}")
        else
          []
        end

      :error ->
        []
    end
  end

  defp parse_ipv4_prefix(base) do
    case String.split(String.trim(base), ".") do
      [a_str, b_str, c_str] ->
        with {:ok, a} <- parse_octet(a_str),
             {:ok, b} <- parse_octet(b_str),
             {:ok, c} <- parse_octet(c_str) do
          {:ok, {a, b, c}}
        else
          _ -> :error
        end

      [a_str, b_str, c_str, d_str] ->
        with {:ok, a} <- parse_octet(a_str),
             {:ok, b} <- parse_octet(b_str),
             {:ok, c} <- parse_octet(c_str),
             {:ok, _d} <- parse_octet(d_str) do
          {:ok, {a, b, c}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_ipv4_quad(base) do
    case String.split(String.trim(base), ".") do
      [a_str, b_str, c_str, d_str] ->
        with {:ok, a} <- parse_octet(a_str),
             {:ok, b} <- parse_octet(b_str),
             {:ok, c} <- parse_octet(c_str),
             {:ok, d} <- parse_octet(d_str) do
          {:ok, {a, b, c, d}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_octet(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 and n <= 255 -> {:ok, n}
      _ -> :error
    end
  end
end
