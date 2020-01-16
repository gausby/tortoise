defmodule Tortoise.Connection.Config do
  @moduledoc false

  # will be used to keep the client/server negotiated config for the
  # connection. The struct contain the defaults that will be used if
  # the connect/connack messages doesn't specify values to the given
  # configurations

  @enforce_keys [:server_keep_alive]
  defstruct session_expiry_interval: 0,
            receive_maximum: 0xFFFF,
            maximum_qos: 2,
            retain_available: true,
            # how big is it actually?
            maximum_packet_size: :infinity,
            assigned_client_identifier: nil,
            topic_alias_maximum: 0,
            wildcard_subscription_available: true,
            subscription_identifiers_available: true,
            shared_subscription_available: true,
            server_keep_alive: nil
end
