defmodule Tortoise.Package.Auth do
  @moduledoc false

  @opcode 15

  # @allowed_properties [:authentication_method, :authentication_data, :reason_string, :user_property]

  alias Tortoise.Package

  @type reason :: :success | :continue_authentication | :re_authenticate

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            reason: reason(),
            properties: [{any(), any()}]
          }
  @enforce_keys [:reason]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            reason: nil,
            properties: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, 0>>) do
    %__MODULE__{reason: coerce_reason_code(0x00)}
  end

  def decode(<<@opcode::4, 0::4, variable_header::binary>>) do
    <<reason_code::8, properties::binary>> = Package.drop_length_prefix(variable_header)

    %__MODULE__{
      reason: coerce_reason_code(reason_code),
      properties: Package.Properties.decode(properties)
    }
  end

  defp coerce_reason_code(reason_code) do
    case reason_code do
      0x00 -> :success
      0x18 -> :continue_authentication
      0x19 -> :re_authenticate
    end
  end

  defimpl Tortoise.Encodable do
    def encode(%Package.Auth{reason: :success, properties: []} = t) do
      [Package.Meta.encode(t.__META__), 0]
    end

    def encode(%Package.Auth{reason: reason} = t)
        when reason in [:success, :continue_authentication, :re_authenticate] do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<to_reason_code(t.reason)::8>>,
          Package.Properties.encode(t.properties)
        ])
      ]
    end

    defp to_reason_code(reason) do
      case reason do
        :success -> 0x00
        :continue_authentication -> 0x18
        :re_authenticate -> 0x19
      end
    end
  end
end
