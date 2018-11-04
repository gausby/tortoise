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
            properties: [{:reason_string, String.t()}, {:user_property, String.t()}]
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
end
