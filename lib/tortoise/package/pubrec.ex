defmodule Tortoise.Package.Pubrec do
  @moduledoc false

  @opcode 5

  # @allowed_properties [:reason_string, :user_property]

  alias Tortoise.Package

  @type reason :: :success | {:refused, refusal_reasons()}
  @type refusal_reasons ::
          :no_matching_subscribers
          | :unspecified_error
          | :implementation_specific_error
          | :not_authorized
          | :topic_name_invalid
          | :packet_identifier_in_use
          | :quota_exceeded
          | :payload_format_invalid

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            reason: reason(),
            properties: [{:reason_string, String.t()}, {:user_property, {String.t(), String.t()}}]
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b0000},
            identifier: nil,
            reason: :success,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, 2, identifier::big-integer-size(16)>>)
      when identifier in 0x0001..0xFFFF do
    %__MODULE__{identifier: identifier, reason: :success, properties: []}
  end

  def decode(<<@opcode::4, 0::4, variable_header::binary>>) do
    <<identifier::big-integer-size(16), reason_code::8, properties::binary>> =
      Package.drop_length_prefix(variable_header)

    %__MODULE__{
      identifier: identifier,
      reason: coerce_reason_code(reason_code),
      properties: Package.Properties.decode(properties)
    }
  end

  defp coerce_reason_code(reason_code) do
    case reason_code do
      0x00 -> :success
      0x10 -> {:refused, :no_matching_subscribers}
      0x80 -> {:refused, :unspecified_error}
      0x83 -> {:refused, :implementation_specific_error}
      0x87 -> {:refused, :not_authorized}
      0x90 -> {:refused, :topic_name_invalid}
      0x91 -> {:refused, :packet_identifier_in_use}
      0x97 -> {:refused, :quota_exceeded}
      0x99 -> {:refused, :payload_format_invalid}
    end
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(
          %Package.Pubrec{
            identifier: identifier,
            reason: :success,
            properties: []
          } = t,
          _opts
        )
        when identifier in 0x0001..0xFFFF do
      # The Reason Code and Property Length can be omitted if the
      # Reason Code is 0x00 (Success) and there are no Properties
      [Package.Meta.encode(t.__META__), <<2, identifier::big-integer-size(16)>>]
    end

    def encode(%Package.Pubrec{identifier: identifier} = t, _opts)
        when identifier in 0x0001..0xFFFF do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16), to_reason_code(t.reason)::8>>,
          Package.Properties.encode(t.properties)
        ])
      ]
    end

    defp to_reason_code(:success), do: 0x00

    defp to_reason_code({:refused, reason}) do
      case reason do
        :no_matching_subscribers -> 0x10
        :unspecified_error -> 0x80
        :implementation_specific_error -> 0x83
        :not_authorized -> 0x87
        :topic_name_invalid -> 0x90
        :packet_identifier_in_use -> 0x91
        :quota_exceeded -> 0x97
        :payload_format_invalid -> 0x99
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
        |> bind(&gen_reason/1)
        |> bind(&gen_properties/1)
        |> bind(fn data ->
          fixed_map([
            {:__struct__, type}
            | for({k, v} <- data, do: {k, constant(v)})
          ])
        end)
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
        :no_matching_subscribers,
        :unspecified_error,
        :implementation_specific_error,
        :not_authorized,
        :topic_name_invalid,
        :packet_identifier_in_use,
        :quota_exceeded,
        :payload_format_invalid
      ]

      defp gen_reason(values) do
        case Keyword.pop(values, :reason) do
          {nil, values} ->
            fixed_list([
              {
                constant(:reason),
                StreamData.frequency([
                  {60, constant(:success)},
                  {40, tuple({constant(:refused), one_of(@refusals)})}
                ])
              }
              | Enum.map(values, &constant(&1))
            ])

          {{:refused, nil}, values} ->
            fixed_list([
              {:reason, tuple({constant(:refused), one_of(@refusals)})}
              | Enum.map(values, &constant(&1))
            ])

          {:success, _} ->
            constant(values)

          {{:refused, refusal_reason}, _} when refusal_reason in @refusals ->
            constant(values)
        end
      end

      defp gen_properties(values) do
        case Keyword.pop(values, :properties) do
          {nil, values} ->
            properties =
              uniq_list_of(
                one_of([
                  # here we allow stings with a byte size of zero; don't
                  # know if that is a problem according to the spec. Let's
                  # handle that situation just in case:
                  {constant(:user_property), {string(:printable), string(:printable)}},
                  {constant(:reason_string), string(:printable)}
                ]),
                uniq_fun: &uniq/1,
                max_length: 5
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
