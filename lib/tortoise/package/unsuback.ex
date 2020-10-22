defmodule Tortoise.Package.Unsuback do
  @moduledoc false

  @opcode 11

  # @allowed_properties [:reason_string, :user_property]

  alias Tortoise.Package

  @type refusal ::
          :no_subscription_existed
          | :unspecified_error
          | :implementation_specific_error
          | :not_authorized
          | :topic_filter_invalid
          | :packet_identifier_in_use

  @type result() :: :success | {:error, refusal()}

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            results: [:success | {:error, refusal}],
            properties: [
              {:reason_string, String.t()}
              | {:user_property, {String.t(), String.t()}}
            ]
          }
  @enforce_keys [:identifier]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b0000},
            identifier: nil,
            results: [],
            properties: []

  @spec decode(binary()) :: t | {:error, term()}
  def decode(<<@opcode::4, 0::4, package::binary>>) do
    with payload <- drop_length(package),
         <<identifier::big-integer-size(16), rest::binary>> <- payload,
         {properties, unsubacks} = Package.parse_variable_length(rest) do
      case return_codes_to_list(unsubacks) do
        [] ->
          {:error, {:protocol_violation, :empty_unsubscription_ack}}

        results ->
          %__MODULE__{
            identifier: identifier,
            results: results,
            properties: Package.Properties.decode(properties)
          }
      end
    end
  end

  defp return_codes_to_list(<<>>), do: []

  defp return_codes_to_list(<<reason::8, rest::binary>>) do
    [
      case reason do
        0x00 -> :success
        0x11 -> {:error, :no_subscription_existed}
        0x80 -> {:error, :unspecified_error}
        0x83 -> {:error, :implementation_specific_error}
        0x87 -> {:error, :not_authorized}
        0x8F -> {:error, :topic_filter_invalid}
        0x91 -> {:error, :packet_identifier_in_use}
      end
    ] ++ return_codes_to_list(rest)
  end

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(%Package.Unsuback{identifier: identifier} = t, _opts)
        when identifier in 0x0001..0xFFFF do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16)>>,
          Package.Properties.encode(t.properties),
          Enum.map(t.results, &encode_result/1)
        ])
      ]
    end

    defp encode_result(:success), do: 0x00

    defp encode_result({:error, reason}) do
      case reason do
        :no_subscription_existed -> 0x11
        :unspecified_error -> 0x80
        :implementation_specific_error -> 0x83
        :not_authorized -> 0x87
        :topic_filter_invalid -> 0x8F
        :packet_identifier_in_use -> 0x91
      end
    end
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl Tortoise.Generatable do
      import StreamData

      def generate(%type{__META__: _meta} = package) do
        values = package |> Map.from_struct()

        fixed_list(Enum.map(values, &constant(&1)))
        |> bind(&gen_identifier/1)
        |> bind(&gen_results/1)
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
        :no_subscription_existed,
        :unspecified_error,
        :implementation_specific_error,
        :not_authorized,
        :topic_filter_invalid,
        :packet_identifier_in_use
      ]

      defp gen_results(values) do
        # Rule: An empty ack list is not allowed; it is a protocol
        # error to not acknowledge or rejct at least one subscription
        case Keyword.pop(values, :results) do
          {nil, values} ->
            fixed_list([
              {constant(:results), nonempty(list_of(do_gen_result()))}
              | Enum.map(values, &constant(&1))
            ])

          # Generate the results list based on a list containing either
          # valid success/error tuples, or nils, where nils will get
          # replaced with an result generator. This allow us to generate
          # lists with a fixed length and with specific spots filled
          # with particular values
          {[_ | _] = results, values} ->
            fixed_list([
              {constant(:results),
               fixed_list(
                 Enum.map(results, fn
                   nil -> do_gen_result()
                   :success -> constant(:success)
                   {:error, e} = value when e in @refusals -> constant(value)
                   {:error, nil} -> {constant(:error), one_of(@refusals)}
                 end)
               )}
              | Enum.map(values, &constant(&1))
            ])
        end
      end

      defp do_gen_result() do
        frequency([
          {60, constant(:success)},
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
