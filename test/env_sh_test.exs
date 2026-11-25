defmodule Tylwyth.EnvShTest do
  use ExUnit.Case, async: true

  @env_sh Path.expand("../priv/env.sh", __DIR__)

  defp run_env_sh(env, mock_bin_dir) do
    path_env = "#{mock_bin_dir}:#{System.get_env("PATH")}"

    cmd = ~S"""
    set -e
    . "$TYLWYTH_ENV_SH"
    printf 'RELEASE_NODE=%s\nERL_AFLAGS=%s\nERL_EPMD_ADDRESS=%s\n' \
      "${RELEASE_NODE:-}" "${ERL_AFLAGS:-}" "${ERL_EPMD_ADDRESS:-}"
    """

    {output, 0} =
      System.cmd("sh", ["-c", cmd], env: [{"PATH", path_env}, {"TYLWYTH_ENV_SH", @env_sh} | env])

    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  test "supports static distribution port without local interface binding when NODE_IP is not on local NIC" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tylwyth_mock_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    ip_script = Path.join(tmp_dir, "ip")

    File.write!(ip_script, """
    #!/bin/sh
    echo "2: eth0    inet 172.18.0.5/16 brd 172.18.255.255 scope global eth0"
    """)

    File.chmod!(ip_script, 0o755)

    result =
      run_env_sh(
        [
          {"NODE_BASENAME", "myapp"},
          {"NODE_IP", "10.2.0.3"},
          {"RELEASE_DISTRIBUTION", nil},
          {"RELEASE_NODE", nil},
          {"ERL_AFLAGS", nil},
          {"ERL_EPMD_ADDRESS", nil},
          {"ERL_DIST_STATIC_PORT", "9145"}
        ],
        tmp_dir
      )

    assert result["RELEASE_NODE"] == "myapp@10.2.0.3"
    assert result["ERL_AFLAGS"] =~ "inet_dist_listen_min 9145"
    assert result["ERL_AFLAGS"] =~ "inet_dist_listen_max 9145"
    assert result["ERL_AFLAGS"] =~ "-start_epmd false -erl_epmd_port 9145"
    refute result["ERL_AFLAGS"] =~ "inet_dist_use_interface"
    assert result["ERL_EPMD_ADDRESS"] == ""
  end

  test "binds inet_dist_use_interface when NODE_IP is present on local NIC with static port" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tylwyth_mock_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    ip_script = Path.join(tmp_dir, "ip")

    File.write!(ip_script, """
    #!/bin/sh
    echo "3: wg0    inet 10.2.0.3/24 brd 10.2.0.255 scope global wg0"
    """)

    File.chmod!(ip_script, 0o755)

    result =
      run_env_sh(
        [
          {"NODE_BASENAME", "myapp"},
          {"NODE_IP", "10.2.0.3"},
          {"RELEASE_DISTRIBUTION", nil},
          {"RELEASE_NODE", nil},
          {"ERL_AFLAGS", nil},
          {"ERL_EPMD_ADDRESS", nil},
          {"ERL_DIST_STATIC_PORT", "9145"}
        ],
        tmp_dir
      )

    assert result["RELEASE_NODE"] == "myapp@10.2.0.3"
    assert result["ERL_AFLAGS"] =~ "inet_dist_use_interface \"{10,2,0,3}\""
    assert result["ERL_AFLAGS"] =~ "-start_epmd false -erl_epmd_port 9145"
    assert result["ERL_EPMD_ADDRESS"] == ""
  end

  test "ignores public IPs from hostname -I fallback and falls back to 127.0.0.1" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tylwyth_mock_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    ip_script = Path.join(tmp_dir, "ip")
    File.write!(ip_script, "#!/bin/sh\nexit 0\n")
    File.chmod!(ip_script, 0o755)

    hostname_script = Path.join(tmp_dir, "hostname")
    File.write!(hostname_script, "#!/bin/sh\necho '203.0.113.5 172.17.0.1'\n")
    File.chmod!(hostname_script, 0o755)

    result =
      run_env_sh(
        [
          {"NODE_BASENAME", "myapp"},
          {"NODE_IP", nil},
          {"RELEASE_DISTRIBUTION", nil},
          {"RELEASE_NODE", nil},
          {"ERL_AFLAGS", nil},
          {"ERL_EPMD_ADDRESS", nil}
        ],
        tmp_dir
      )

    assert result["RELEASE_NODE"] == "myapp@127.0.0.1"
    assert result["ERL_EPMD_ADDRESS"] == ""
    refute result["ERL_AFLAGS"] =~ "inet_dist_use_interface"
  end

  test "uses fixed-string match for NODE_IP so regex dots do not match unrelated IPs" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tylwyth_mock_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    ip_script = Path.join(tmp_dir, "ip")

    File.write!(ip_script, """
    #!/bin/sh
    echo "3: wg0    inet 10121013/24 scope global wg0"
    """)

    File.chmod!(ip_script, 0o755)

    result =
      run_env_sh(
        [
          {"NODE_BASENAME", "myapp"},
          {"NODE_IP", "10.2.0.3"},
          {"RELEASE_DISTRIBUTION", nil},
          {"RELEASE_NODE", nil},
          {"ERL_AFLAGS", nil},
          {"ERL_EPMD_ADDRESS", nil},
          {"ERL_DIST_STATIC_PORT", "9145"}
        ],
        tmp_dir
      )

    refute result["ERL_AFLAGS"] =~ "inet_dist_use_interface"
  end

  test "rejects malformed ERL_DIST_STATIC_PORT and warns on DEFAULT_RELEASE_COOKIE fallback" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tylwyth_mock_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    cmd = ~S"""
    . "$TYLWYTH_ENV_SH"
    printf 'ERL_AFLAGS=%s\nRELEASE_COOKIE=%s\n' "${ERL_AFLAGS:-}" "${RELEASE_COOKIE:-}"
    """

    {output, 0} =
      System.cmd("sh", ["-c", cmd],
        stderr_to_stdout: true,
        env: [
          {"TYLWYTH_ENV_SH", @env_sh},
          {"NODE_BASENAME", "myapp"},
          {"NODE_IP", "10.2.0.3"},
          {"RELEASE_COOKIE", nil},
          {"CLUSTER_COOKIE", nil},
          {"DEFAULT_RELEASE_COOKIE", "dev_only_cookie"},
          {"ERL_DIST_STATIC_PORT", "9145 -eval evil"},
          {"ERL_AFLAGS", nil}
        ]
      )

    assert output =~ "WARNING: RELEASE_COOKIE is unset"
    assert output =~ "Ignoring invalid ERL_DIST_STATIC_PORT"

    assert [erl_aflags_line] =
             Enum.filter(String.split(output, "\n"), &String.starts_with?(&1, "ERL_AFLAGS="))

    refute erl_aflags_line =~ "-eval evil"
    refute erl_aflags_line =~ "-erl_epmd_port"
    assert output =~ "RELEASE_COOKIE=dev_only_cookie"
  end
end
