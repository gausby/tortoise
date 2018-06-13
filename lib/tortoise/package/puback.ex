defmodule Tortoise.Package.Puback do
  @moduledoc false

  @opcode 4

  alias Tortoise.Package

  @type package_identifier :: 0x0001..0xFFFF

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: package_identifier() | nil
          }
  @enforce_keys [:identifier]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b0000},
            identifier: nil

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, 2, identifier::big-integer-size(16)>>)
      when identifier in 0x0001..0xFFFF do
    %__MODULE__{identifier: identifier}
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(%Package.Puback{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [Package.Meta.encode(t.__META__), <<2, identifier::big-integer-size(16)>>]
    end
  end
end
