defmodule Tortoise.Package.Pubrel do
  @moduledoc false

  @opcode 6

  # @allowed_properties [:reason_string, :user_property]

  alias Tortoise.Package

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier(),
            reason: :success | {:refused, :packet_identifier_not_found},
            properties: []
          }
  @enforce_keys [:identifier]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b0010},
            identifier: nil,
            reason: :success,
            properties: []

  @spec decode(<<_::32>>) :: t
  def decode(<<@opcode::4, 2::4, 2, identifier::big-integer-size(16)>>)
      when identifier in 0x0001..0xFFFF do
    %__MODULE__{identifier: identifier}
  end

  def decode(<<@opcode::4, 2::4, variable_header::binary>>) do
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
          %Package.Pubrel{
            identifier: identifier,
            reason: :success,
            properties: []
          } = t
        )
        when identifier in 0x0001..0xFFFF do
      # The Reason Code and Property Length can be omitted if the
      # Reason Code is 0x00 (Success) and there are no Properties
      [Package.Meta.encode(t.__META__), <<2, identifier::big-integer-size(16)>>]
    end

    def encode(%Package.Pubrel{identifier: identifier} = t)
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
