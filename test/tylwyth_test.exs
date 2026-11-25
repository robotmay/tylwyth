defmodule TylwythTest do
  use ExUnit.Case, async: false

  test "discovers real OTP peer node via EPMD/extra_nodes, invokes on_connect, and reports cluster_info" do
    was_alive? = Node.alive?()
    {_out, _} = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    if not was_alive? do
      primary_name = :"tylwyth_primary_#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start([primary_name, :longnames])
    end

    prev_cookie = Node.get_cookie()
    cookie = :tylwyth_test_cookie
    Node.set_cookie(cookie)

    peer_short = :"tylwyth_peer_#{System.unique_integer([:positive])}"

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{
        name: peer_short,
        host: ~c"127.0.0.1",
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(cookie)]
      })

    Node.disconnect(peer_node)
    refute peer_node in Node.list()

    on_exit(fn ->
      try do
        :peer.stop(peer_pid)
      catch
        _, _ -> :ok
      end

      Node.set_cookie(prev_cookie)

      if not was_alive? do
        :net_kernel.stop()
      end
    end)

    test_pid = self()

    start_supervised!(
      {Tylwyth,
       name: :tylwyth_test_sweeper,
       basename: "tylwyth_peer",
       enabled: false,
       extra_nodes: fn -> [peer_node] end,
       on_connect: fn target -> send(test_pid, {:connected_peer, target}) end}
    )

    assert peer_node in Tylwyth.local_epmd_nodes()

    results = Tylwyth.sweep(:tylwyth_test_sweeper)
    assert {:connected, peer_node} in results
    assert peer_node in Tylwyth.connected_nodes()
    assert_receive {:connected_peer, ^peer_node}, 5_000

    info = Tylwyth.cluster_info()
    assert info.self == node()
    assert peer_node in info.connected_nodes
    assert info.node_count >= 2
    assert info.distributed? == true
    assert info.is_distributed == true
    assert is_binary(info.private_ip)

    assert {:error, :invalid_node_name} = Tylwyth.connect_node("invalid")
    assert {:error, :invalid_node_name} = Tylwyth.connect_node("bad name@10.0.0.1")
    assert {:error, :invalid_node_name} = Tylwyth.connect_node("a@b@c")
    assert {:ok, ^peer_node} = Tylwyth.connect_node(peer_node)
  end

  test "priv/env.sh sets RELEASE_NODE, RELEASE_COOKIE, ERL_EPMD_ADDRESS, and inet_dist_use_interface" do
    env_script = Path.expand("../priv/env.sh", __DIR__)

    {out, 0} =
      System.cmd(
        "/bin/sh",
        [
          "-c",
          ". #{inspect(env_script)} && printf '%s\\n%s\\n%s\\n%s' \"$RELEASE_NODE\" \"$RELEASE_COOKIE\" \"$ERL_EPMD_ADDRESS\" \"$ERL_AFLAGS\""
        ],
        env: [
          {"NODE_BASENAME", "myapp"},
          {"NODE_IP", "10.0.0.42"},
          {"CLUSTER_COOKIE", "test_cluster_cookie"},
          {"RELEASE_NODE", nil},
          {"RELEASE_COOKIE", nil}
        ]
      )

    assert [node_val, cookie_val, epmd_val, erl_aflags] = String.split(out, "\n")
    assert node_val == "myapp@10.0.0.42"
    assert cookie_val == "test_cluster_cookie"
    assert epmd_val == "10.0.0.42"
    assert erl_aflags =~ ~s(inet_dist_use_interface "{10,0,0,42}")
    assert erl_aflags =~ "inet_dist_listen_min 9100"
    assert erl_aflags =~ "inet_dist_listen_max 9105"
  end

  test "local_epmd_nodes returns [] when ERL_DIST_STATIC_PORT is set" do
    prev_val = System.get_env("ERL_DIST_STATIC_PORT")
    System.put_env("ERL_DIST_STATIC_PORT", "9145")

    on_exit(fn ->
      case prev_val do
        nil -> System.delete_env("ERL_DIST_STATIC_PORT")
        val -> System.put_env("ERL_DIST_STATIC_PORT", val)
      end
    end)

    assert Tylwyth.local_epmd_nodes() == []
  end

  test "priv/env.sh configures -start_epmd false -erl_epmd_port when ERL_DIST_STATIC_PORT is set" do
    env_script = Path.expand("../priv/env.sh", __DIR__)

    {out, 0} =
      System.cmd(
        "/bin/sh",
        [
          "-c",
          ". #{inspect(env_script)} && printf '%s\\n%s\\n%s' \"$RELEASE_NODE\" \"$RELEASE_COOKIE\" \"$ERL_AFLAGS\""
        ],
        env: [
          {"NODE_BASENAME", "myapp"},
          {"NODE_IP", "10.2.0.2"},
          {"CLUSTER_COOKIE", "test_cluster_cookie"},
          {"ERL_DIST_STATIC_PORT", "9145"},
          {"RELEASE_NODE", nil},
          {"RELEASE_COOKIE", nil},
          {"ERL_AFLAGS", nil}
        ]
      )

    assert [node_val, cookie_val, erl_aflags] = String.split(out, "\n")
    assert node_val == "myapp@10.2.0.2"
    assert cookie_val == "test_cluster_cookie"
    assert erl_aflags =~ "inet_dist_listen_min 9145"
    assert erl_aflags =~ "inet_dist_listen_max 9145"
    assert erl_aflags =~ "-start_epmd false -erl_epmd_port 9145"
  end
end
