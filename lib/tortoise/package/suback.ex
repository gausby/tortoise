defmodule Tortoise.Package.Suback do
  @moduledoc false

  @opcode 9

  # @allowed_properties [:reason_string, :user_property]

  alias Tortoise.Package

  @type qos :: 0 | 1 | 2
  @type refusal_reason ::
          :unspecified_error
          | :implementation_specific_error
          | :not_authorized
          | :topic_filter_invalid
          | :packet_identifier_in_use
          | :quota_exceeded
          | :shared_subscriptions_not_supported
          | :subscription_identifiers_not_supported
          | :wildcard_subscriptions_not_supported

  @type ack_result :: {:ok, qos} | {:error, refusal_reason()}

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            acks: [ack_result],
            properties: [{:reason_string, String.t()}, {:user_property, {String.t(), String.t()}}]
          }
  @enforce_keys [:identifier]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            identifier: nil,
            acks: [],
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, payload::binary>>) do
    with payload <- drop_length(payload),
         <<identifier::big-integer-size(16), rest::binary>> <- payload,
         {properties, acks} = Package.parse_variable_length(rest) do
      case return_codes_to_list(acks) do
        [] ->
          {:error, {:protocol_violation, :empty_subscription_ack}}

        sub_acks ->
          %__MODULE__{
            identifier: identifier,
            acks: sub_acks,
            properties: Package.Properties.decode(properties)
          }
      end
    end
  end

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  defp return_codes_to_list(<<>>), do: []

  defp return_codes_to_list(<<code::8, rest::binary>>) do
    [
      case code do
        maximum_qos when code in 0x00..0x02 ->
          {:ok, maximum_qos}

        0x80 ->
          {:error, :unspecified_error}

        0x83 ->
          {:error, :implementation_specific_error}

        0x87 ->
          {:error, :not_authorized}

        0x8F ->
          {:error, :topic_filter_invalid}

        0x91 ->
          {:error, :packet_identifier_in_use}

        0x97 ->
          {:error, :quota_exceeded}

        0x9E ->
          {:error, :shared_subscriptions_not_supported}

        0xA1 ->
          {:error, :subscription_identifiers_not_supported}

        0xA2 ->
          {:error, :wildcard_subscriptions_not_supported}
      end
    ] ++ return_codes_to_list(rest)
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(%Package.Suback{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16)>>,
          Package.Properties.encode(t.properties),
          Enum.map(t.acks, &encode_ack/1)
        ])
      ]
    end

    defp encode_ack({:ok, qos}) when qos in 0x00..0x02, do: qos
    defp encode_ack({:error, :unspecified_error}), do: 0x80
    defp encode_ack({:error, :implementation_specific_error}), do: 0x83
    defp encode_ack({:error, :not_authorized}), do: 0x87
    defp encode_ack({:error, :topic_filter_invalid}), do: 0x8F
    defp encode_ack({:error, :packet_identifier_in_use}), do: 0x91
    defp encode_ack({:error, :quota_exceeded}), do: 0x97
    defp encode_ack({:error, :shared_subscriptions_not_supported}), do: 0x9E
    defp encode_ack({:error, :subscription_identifiers_not_supported}), do: 0xA1
    defp encode_ack({:error, :wildcard_subscriptions_not_supported}), do: 0xA2
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl Tortoise.Generatable do
      import StreamData

      def generate(%type{__META__: _meta} = package) do
        values = package |> Map.from_struct()

        fixed_list(Enum.map(values, &constant(&1)))
        |> bind(&gen_identifier/1)
        |> bind(&gen_acks/1)
        |> bind(&gen_properties/1)
        |> bind(&fixed_map([{:__struct__, type} | for({k, v} <- &1, do: {k, constant(v)})]))
      end

      defp gen_identifier(values) do
        case Keyword.pop(values, :identifier) do
          {nil, values} ->
            fixed_list([
              {constant(:identifier), integer(1..0xFFFF)}
              | Enum.map(values, &constant(&1))
            ])

          {id, _} when is_integer(id) and id in 1..0xFFFF ->
            constant(values)
        end
      end

      @refusals [
        :unspecified_error,
        :implementation_specific_error,
        :not_authorized,
        :topic_filter_invalid,
        :packet_identifier_in_use,
        :quota_exceeded,
        :shared_subscriptions_not_supported,
        :subscription_identifiers_not_supported,
        :wildcard_subscriptions_not_supported
      ]

      defp gen_acks(values) do
        # Rule: An empty ack list is not allowed; it is a protocol
        # error to not acknowledge or rejct at least one subscription
        case Keyword.pop(values, :acks) do
          {nil, values} ->
            fixed_list([
              {constant(:acks), nonempty(list_of(do_gen_ack()))}
              | Enum.map(values, &constant(&1))
            ])

          # Generate the acks list based on a list containing either
          # valid ok/error tuples, or nils, where nils will get
          # replaced with an ack generator. This allow us to generate
          # lists with a fixed length and with specific spots filled
          # with particular values
          {[_ | _] = acks, values} ->
            fixed_list([
              {constant(:acks),
               fixed_list(
                 Enum.map(acks, fn
                   nil -> do_gen_ack()
                   {:ok, n} = value when n in 0..2 -> constant(value)
                   {:ok, nil} -> {constant(:ok), integer(0..2)}
                   {:error, e} = value when e in @refusals -> constant(value)
                   {:error, nil} -> {constant(:error), one_of(@refusals)}
                 end)
               )}
              | Enum.map(values, &constant(&1))
            ])
        end
      end

      defp do_gen_ack() do
        frequency([
          {60, tuple({constant(:ok), integer(0..2)})},
          {40, tuple({constant(:error), one_of(@refusals)})}
        ])
      end

      defp gen_properties(values) do
        case Keyword.pop(values, :properties) do
          {nil, values} ->
            properties =
              uniq_list_of(
                frequency([
                  # here we allow stings with a byte size of zero; don't
                  # know if that is a problem according to the spec. Let's
                  # handle that situation just in case:
                  {4, {constant(:user_property), {string(:printable), string(:printable)}}},
                  {1, {constant(:reason_string), string(:printable)}}
                ]),
                uniq_fun: &uniq/1,
                max_length: 20
              )

            fixed_list([
              {constant(:properties), properties}
              | Enum.map(values, &constant(&1))
            ])

          {_passthrough, _} ->
            constant(values)
        end
      end

      defp uniq({:user_property, _v}), do: :crypto.strong_rand_bytes(2)
      defp uniq({k, _v}), do: k
    end
  end
end
