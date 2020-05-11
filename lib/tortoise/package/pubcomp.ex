defmodule Tortoise.Package.Pubcomp do
  @moduledoc false

  @opcode 7

  # @allowed_properties [:reason_string, :user_property]

  alias Tortoise.Package

  @type reason :: :success | {:refused, refusal_reasons()}
  @type refusal_reasons :: :packet_identifier_not_found

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            reason: reason(),
            properties: [{:reason_string, String.t()}, {:user_property, {String.t(), String.t()}}]
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            identifier: nil,
            reason: :success,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, 2, identifier::big-integer-size(16)>>)
      when identifier in 0x0001..0xFFFF do
    %__MODULE__{identifier: identifier}
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
      0x92 -> {:refused, :packet_identifier_not_found}
    end
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(
          %Package.Pubcomp{
            identifier: identifier,
            reason: :success,
            properties: []
          } = t
        )
        when identifier in 0x0001..0xFFFF do
      [Package.Meta.encode(t.__META__), <<2, t.identifier::big-integer-size(16)>>]
    end

    def encode(%Package.Pubcomp{identifier: identifier} = t)
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
    defp to_reason_code({:refused, :packet_identifier_not_found}), do: 0x92
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

      # Might be overkill, but at least we are prepared for more
      # refusal reasons in the future should there be more refusals in
      # a future protocol version
      @refusals [:packet_identifier_not_found]

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
