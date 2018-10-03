defmodule Tortoise.Package.Properties do
  @moduledoc false

  alias Tortoise.Package

  import Tortoise.Package, only: [variable_length: 1, length_encode: 1]

  def encode(data) when is_list(data) do
    data
    |> Enum.map(&encode_property/1)
    |> Package.variable_length_encode()
  end

  # User properties are special; we will allow them to be encoded as
  # binaries to make the interface a bit cleaner to the end user
  #
  # Todo, revert this decision
  defp encode_property({key, value}) when is_binary(key) do
    [0x26, length_encode(key), length_encode(value)]
  end

  defp encode_property({key, value}) do
    case key do
      :payload_format_indicator ->
        [0x01, <<value::8>>]

      :message_expiry_interval ->
        [0x02, <<value::integer-size(32)>>]

      :content_type ->
        [0x03, length_encode(value)]

      :response_topic ->
        [0x08, length_encode(value)]

      :correlation_data ->
        [0x09, length_encode(value)]

      :subscription_identifier when is_integer(value) ->
        [0x0B, variable_length(value)]

      :session_expiry_interval ->
        [0x11, <<value::integer-size(32)>>]

      :assigned_client_identifier ->
        [0x12, length_encode(value)]

      :server_keep_alive ->
        [0x13, <<value::integer-size(16)>>]

      :authentication_method ->
        [0x15, length_encode(value)]

      :authentication_data when is_binary(value) ->
        [0x16, length_encode(value)]

      :request_problem_information ->
        [0x17, <<value::8>>]

      :will_delay_interval when is_integer(value) ->
        [0x18, <<value::integer-size(32)>>]

      :request_response_information ->
        [0x19, <<value::8>>]

      :response_information ->
        [0x1A, length_encode(value)]

      :server_reference ->
        [0x1C, length_encode(value)]

      :reason_string ->
        [0x1F, length_encode(value)]

      :receive_maximum ->
        [0x21, <<value::integer-size(16)>>]

      :topic_alias_maximum ->
        [0x22, <<value::integer-size(16)>>]

      :topic_alias ->
        [0x23, <<value::integer-size(16)>>]

      :maximum_qos ->
        [0x24, <<value::8>>]

      :retain_available ->
        [0x25, <<value::8>>]

      :maximum_packet_size ->
        [0x27, <<value::integer-size(32)>>]

      :wildcard_subscription_available ->
        [0x28, <<value::8>>]

      :subscription_identifier_available ->
        [0x29, <<value::8>>]

      :shared_subscription_available ->
        [0x2A, <<value::8>>]
    end
  end

  # ---
  def decode(data) do
    data
    |> Package.drop_length_prefix()
    |> do_decode()
  end

  defp do_decode(data) do
    data
    |> decode_property()
    |> case do
      {nil, <<>>} -> []
      {decoded, rest} -> [decoded] ++ do_decode(rest)
    end
  end

  defp decode_property(<<>>) do
    {nil, <<>>}
  end

  defp decode_property(<<0x01, value::8, rest::binary>>) do
    {{:payload_format_indicator, value}, rest}
  end

  defp decode_property(<<0x02, value::integer-size(32), rest::binary>>) do
    {{:message_expiry_interval, value}, rest}
  end

  defp decode_property(<<0x03, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:content_type, value}, rest}
  end

  defp decode_property(<<0x08, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:response_topic, value}, rest}
  end

  defp decode_property(<<0x09, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:correlation_data, value}, rest}
  end

  defp decode_property(<<0x0B, rest::binary>>) do
    case rest do
      <<0::1, value::integer-size(7), rest::binary>> ->
        {{:subscription_identifier, value}, rest}

      <<1::1, a::7, 0::1, b::7, rest::binary>> ->
        <<value::integer-size(14)>> = <<b::7, a::7>>
        {{:subscription_identifier, value}, rest}

      <<1::1, a::7, 1::1, b::7, 0::1, c::7, rest::binary>> ->
        <<value::integer-size(21)>> = <<c::7, b::7, a::7>>
        {{:subscription_identifier, value}, rest}

      <<1::1, a::7, 1::1, b::7, 1::1, c::7, 0::1, d::7, rest::binary>> ->
        <<value::integer-size(28)>> = <<d::7, c::7, b::7, a::7>>
        {{:subscription_identifier, value}, rest}
    end
  end

  defp decode_property(<<0x11, value::integer-size(32), rest::binary>>) do
    {{:session_expiry_interval, value}, rest}
  end

  defp decode_property(<<0x12, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:assigned_client_identifier, value}, rest}
  end

  defp decode_property(<<0x13, value::integer-size(16), rest::binary>>) do
    {{:server_keep_alive, value}, rest}
  end

  defp decode_property(<<0x15, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:authentication_method, value}, rest}
  end

  defp decode_property(<<0x16, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:authentication_data, value}, rest}
  end

  defp decode_property(<<0x17, value::8, rest::binary>>) do
    {{:request_problem_information, value}, rest}
  end

  defp decode_property(<<0x18, value::integer-size(32), rest::binary>>) do
    {{:will_delay_interval, value}, rest}
  end

  defp decode_property(<<0x19, value::8, rest::binary>>) do
    {{:request_response_information, value}, rest}
  end

  defp decode_property(<<0x1A, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:response_information, value}, rest}
  end

  defp decode_property(<<0x1C, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:server_reference, value}, rest}
  end

  defp decode_property(<<0x1F, length::integer-size(16), rest::binary>>) do
    <<value::binary-size(length), rest::binary>> = rest
    {{:reason_string, value}, rest}
  end

  defp decode_property(<<0x21, value::integer-size(16), rest::binary>>) do
    {{:receive_maximum, value}, rest}
  end

  defp decode_property(<<0x22, value::integer-size(16), rest::binary>>) do
    {{:topic_alias_maximum, value}, rest}
  end

  defp decode_property(<<0x23, value::integer-size(16), rest::binary>>) do
    {{:topic_alias, value}, rest}
  end

  defp decode_property(<<0x24, value::8, rest::binary>>) do
    {{:maximum_qos, value}, rest}
  end

  defp decode_property(<<0x25, value::8, rest::binary>>) do
    {{:retain_available, value}, rest}
  end

  defp decode_property(<<0x26, rest::binary>>) do
    <<length::integer-size(16), rest::binary>> = rest
    <<key::binary-size(length), rest::binary>> = rest
    <<length::integer-size(16), rest::binary>> = rest
    <<value::binary-size(length), rest::binary>> = rest
    {{key, value}, rest}
  end

  defp decode_property(<<0x27, value::integer-size(32), rest::binary>>) do
    {{:maximum_packet_size, value}, rest}
  end

  defp decode_property(<<0x28, value::8, rest::binary>>) do
    {{:wildcard_subscription_available, value}, rest}
  end

  defp decode_property(<<0x29, value::8, rest::binary>>) do
    {{:subscription_identifier_available, value}, rest}
  end

  defp decode_property(<<0x2A, value::8, rest::binary>>) do
    {{:shared_subscription_available, value}, rest}
  end
end
