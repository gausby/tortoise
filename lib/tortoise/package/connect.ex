defmodule Tortoise.Package.Connect do
  @moduledoc false

  @opcode 1

  @allowed_properties [
    :authentication_data,
    :authentication_method,
    :maximum_packet_size,
    :receive_maximum,
    :request_problem_information,
    :request_response_information,
    :session_expiry_interval,
    :topic_alias_maximum,
    :user_property
  ]

  alias Tortoise.Package

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            protocol: binary(),
            protocol_version: non_neg_integer(),
            user_name: binary() | nil,
            password: binary() | nil,
            clean_start: boolean(),
            keep_alive: non_neg_integer(),
            client_id: Tortoise.client_id(),
            will: Package.Publish.t() | nil,
            properties: [{any(), any()}]
          }
  @enforce_keys [:client_id]
  defstruct __META__: %Package.Meta{opcode: @opcode},
            protocol: "MQTT",
            protocol_version: 0b00000101,
            user_name: nil,
            password: nil,
            clean_start: true,
            keep_alive: 60,
            client_id: nil,
            will: nil,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, variable::binary>>) do
    <<
      4::big-integer-size(16),
      "MQTT",
      5::8,
      user_name::1,
      password::1,
      will_retain::1,
      will_qos::2,
      will::1,
      clean_start::1,
      0::1,
      keep_alive::big-integer-size(16),
      rest::binary
    >> = drop_length(variable)

    {properties, package} = Package.parse_variable_length(rest)
    properties = Package.Properties.decode(properties)

    payload =
      decode_payload(
        [
          client_id: true,
          will_properties: will == 1,
          will_topic: will == 1,
          will_payload: will == 1,
          user_name: user_name == 1,
          password: password == 1
        ],
        package
      )

    %__MODULE__{
      client_id: payload[:client_id],
      user_name: payload[:user_name],
      password: payload[:password],
      will:
        if will == 1 do
          %Package.Publish{
            topic: payload[:will_topic],
            payload: nullify(payload[:will_payload]),
            qos: will_qos,
            retain: will_retain == 1,
            properties: payload[:will_properties]
          }
        end,
      clean_start: clean_start == 1,
      keep_alive: keep_alive,
      properties: properties
    }
  end

  defp decode_payload([], <<>>) do
    []
  end

  defp decode_payload([{_ignored, false} | remaining_fields], payload) do
    decode_payload(remaining_fields, payload)
  end

  defp decode_payload(
         [{:will_properties, true} | remaining_fields],
         payload
       ) do
    {properties, rest} = Package.parse_variable_length(payload)
    value = Package.Properties.decode(properties)
    [{:will_properties, value}] ++ decode_payload(remaining_fields, rest)
  end

  defp decode_payload(
         [{field, true} | remaining_fields],
         <<length::big-integer-size(16), payload::binary>>
       ) do
    <<value::binary-size(length), rest::binary>> = payload
    [{field, value}] ++ decode_payload(remaining_fields, rest)
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

  defimpl Tortoise.Encodable do
    def encode(%Package.Connect{client_id: client_id} = t)
        when is_binary(client_id) do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          protocol_header(t),
          connection_flags(t),
          keep_alive(t),
          Package.Properties.encode(t.properties),
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
        flag(f.clean_start)::integer-size(1),
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
        flag(f.clean_start)::integer-size(1),
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
      options = [
        f.client_id,
        f.will.properties,
        f.will.topic,
        encode_payload(f.will.payload),
        f.user_name,
        f.password
      ]

      for data <- options,
          data != nil do
        case data do
          data when is_binary(data) ->
            Package.length_encode(data)

          data when is_list(data) ->
            Package.Properties.encode(data)
        end
      end
    end

    defp encode_payload(nil), do: ""
    defp encode_payload(payload), do: payload

    defp flag(f) when f in [0, nil, false], do: 0
    defp flag(_), do: 1
  end
end
