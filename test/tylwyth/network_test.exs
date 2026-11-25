defmodule Tylwyth.NetworkTest do
  use ExUnit.Case, async: true

  alias Tylwyth.Network

  test "valid_ip?/1 accepts IPv4 and IPv6 addresses and rejects invalid strings" do
    assert Network.valid_ip?("10.0.0.4")
    assert Network.valid_ip?("192.168.1.10")
    assert Network.valid_ip?("::1")
    refute Network.valid_ip?("not-an-ip")
    refute Network.valid_ip?(nil)
    refute Network.valid_ip?(123)
  end

  test "detect_private_ip_from_ifaddrs/1 skips Docker bridge subnets and public IPs" do
    ifaddrs = [
      {~c"lo", [addr: {127, 0, 0, 1}]},
      {~c"eth0", [addr: {203, 0, 113, 10}]},
      {~c"docker0", [addr: {172, 17, 0, 1}]},
      {~c"br-abc", [addr: {172, 18, 0, 1}]},
      {~c"br-def", [addr: {172, 20, 0, 1}]},
      {~c"eth1", [addr: {10, 42, 3, 19}]}
    ]

    assert Network.detect_private_ip_from_ifaddrs(ifaddrs) == "10.42.3.19"
    assert Network.detect_private_subnet_from_ifaddrs(ifaddrs) == "10.42.3.0/24"
  end

  test "detect_private_ip_from_ifaddrs/1 supports allowed 172.16-31 and 192.168 interfaces" do
    ifaddrs_192 = [{~c"en0", [addr: {192, 168, 50, 7}]}]
    assert Network.detect_private_ip_from_ifaddrs(ifaddrs_192) == "192.168.50.7"
    assert Network.detect_private_subnet_from_ifaddrs(ifaddrs_192) == "192.168.50.0/24"

    ifaddrs_172 = [{~c"wg0", [addr: {172, 24, 9, 2}]}]
    assert Network.detect_private_ip_from_ifaddrs(ifaddrs_172) == "172.24.9.2"
    assert Network.detect_private_subnet_from_ifaddrs(ifaddrs_172) == "172.24.9.0/24"
  end

  test "generate_subnet_nodes/2 expands /24, /16, and prefix inputs cleanly" do
    nodes_24 = Network.generate_subnet_nodes("10.0.5.0/24", "myapp")
    assert length(nodes_24) == 254
    assert :"myapp@10.0.5.1" in nodes_24
    assert :"myapp@10.0.5.254" in nodes_24

    nodes_16 = Network.generate_subnet_nodes("10.9.0.0/16", "worker")
    assert length(nodes_16) == 508
    assert :"worker@10.9.0.1" in nodes_16
    assert :"worker@10.9.1.254" in nodes_16

    nodes_prefix = Network.generate_subnet_nodes("192.168.8", "myapp")
    assert length(nodes_prefix) == 254
    assert :"myapp@192.168.8.12" in nodes_prefix
  end

  test "generate_subnet_nodes/2 rejects public CIDRs, invalid octets, and invalid basenames" do
    assert Network.generate_subnet_nodes("8.8.8.0/24", "myapp") == []
    assert Network.generate_subnet_nodes("999.0.0.0/24", "myapp") == []
    assert Network.generate_subnet_nodes("foo.bar.baz/24", "myapp") == []
    assert Network.generate_subnet_nodes("10.0.5.0/24", "bad name") == []
    assert Network.generate_subnet_nodes("10.0.5.0/8", "myapp") == []
  end

  test "parse_node_list/1 parses comma-separated binaries and lists while filtering junk" do
    assert Network.parse_node_list(nil) == []
    assert Network.parse_node_list("") == []

    assert Network.parse_node_list(
             " a@10.0.0.1 , b@10.0.0.2, invalid , bad name@10.0.0.1, a@b@c, a@10.0.0.1 "
           ) == [
             :"a@10.0.0.1",
             :"b@10.0.0.2"
           ]

    assert Network.parse_node_list([:"x@10.0.0.3", "y@10.0.0.4", "bad", "foo bar@host"]) == [
             :"x@10.0.0.3",
             :"y@10.0.0.4"
           ]
  end

  test "valid_node_name?/1 validates basenames and hosts" do
    assert Network.valid_node_name?("myapp@10.0.0.1")
    assert Network.valid_node_name?("node_1-a@peer-01.internal")
    assert Network.valid_node_name?("myapp@localhost")
    refute Network.valid_node_name?("")
    refute Network.valid_node_name?("no_at_sign")
    refute Network.valid_node_name?("bad name@10.0.0.1")
    refute Network.valid_node_name?("a@b@c")
    refute Network.valid_node_name?("myapp@.invalid")
  end
end
