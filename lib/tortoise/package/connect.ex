defmodule Tortoise.Package.Connect do
  @moduledoc false

  @opcode 1

  alias Tortoise.Package

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            protocol: binary(),
            protocol_version: non_neg_integer(),
            user_name: binary() | nil,
            password: binary() | nil,
            clean_session: boolean(),
            keep_alive: non_neg_integer(),
            client_id: binary(),
            will: Package.Publish.t() | nil
          }
  @enforce_keys [:client_id]
  defstruct __META__: %Package.Meta{opcode: @opcode},
            protocol: "MQTT",
            protocol_version: 0b00000100,
            user_name: nil,
            password: nil,
            clean_session: true,
            keep_alive: 60,
            client_id: nil,
            will: nil

  def decode(<<@opcode::4, 0::4, variable::binary>>) do
    <<4::big-integer-size(16), "MQTT", 4::8, user_name::1, password::1, will_retain::1,
      will_qos::2, will::1, clean_session::1, 0::1, keep_alive::big-integer-size(16),
      package::binary>> = drop_length(variable)

    options =
      [
        client_id: 1,
        will_topic: will,
        will_payload: will,
        user_name: user_name,
        password: password
      ]
      |> Enum.filter(fn {_, present} -> present == 1 end)
      |> Enum.map(fn {value, 1} -> value end)
      |> Enum.zip(decode_length_prefixed(package))

    %__MODULE__{
      client_id: options[:client_id],
      user_name: options[:user_name],
      password: options[:password],
      will:
        if will == 1 do
          %Package.Publish{
            topic: options[:will_topic],
            payload: nullify(options[:will_payload]),
            qos: will_qos,
            retain: will_retain == 1
          }
        end,
      clean_session: clean_session == 1,
      keep_alive: keep_alive
    }
  end

  defp nullify(""), do: nil
  defp nullify(payload), do: payload

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  defp decode_length_prefixed(<<>>), do: []

  defp decode_length_prefixed(<<length::big-integer-size(16), payload::binary>>) do
    <<item::binary-size(length), rest::binary>> = payload
    [item] ++ decode_length_prefixed(rest)
  end

  defimpl Tortoise.Encodable do
    def encode(%Package.Connect{client_id: client_id} = t)
        when is_binary(client_id) do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          protocol_header(t),
          connection_flags(t),
          keep_alive(t),
          payload(t)
        ])
      ]
    end

    def encode(%Package.Connect{client_id: client_id} = t)
        when is_atom(client_id) do
      encode(%Package.Connect{t | client_id: Atom.to_string(client_id)})
    end

    defp protocol_header(%{protocol: protocol, protocol_version: version}) do
      [Package.length_encode(protocol), version]
    end

    defp connection_flags(%{will: nil} = f) do
      <<
        flag(f.user_name)::integer-size(1),
        flag(f.password)::integer-size(1),
        # will retain
        flag(0)::integer-size(1),
        # will qos
        0::integer-size(2),
        # will flag
        flag(0)::integer-size(1),
        flag(f.clean_session)::integer-size(1),
        # reserved bit
        0::1
      >>
    end

    defp connection_flags(%{will: %Package.Publish{}} = f) do
      <<
        flag(f.user_name)::integer-size(1),
        flag(f.password)::integer-size(1),
        flag(f.will.retain)::integer-size(1),
        f.will.qos::integer-size(2),
        flag(f.will.topic)::integer-size(1),
        flag(f.clean_session)::integer-size(1),
        # reserved bit
        0::1
      >>
    end

    defp keep_alive(f) do
      <<f.keep_alive::big-integer-size(16)>>
    end

    defp payload(%{will: nil} = f) do
      [f.client_id, f.user_name, f.password]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Package.length_encode/1)
    end

    defp payload(f) do
      will_payload = encode_payload(f.will.payload)

      [f.client_id, f.will.topic, will_payload, f.user_name, f.password]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Package.length_encode/1)
    end

    defp encode_payload(nil), do: ""
    defp encode_payload(payload), do: payload

    defp flag(f) when f in [0, nil, false], do: 0
    defp flag(_), do: 1
  end
end
