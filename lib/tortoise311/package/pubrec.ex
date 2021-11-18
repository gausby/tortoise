defmodule Tortoise311.Package.Pubrec do
  @moduledoc false

  @opcode 5

  alias Tortoise311.Package

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise311.package_identifier()
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0b000},
            identifier: nil

  @spec decode(<<_::32>>) :: t
  def decode(<<@opcode::4, 0::4, 2, identifier::big-integer-size(16)>>)
      when identifier in 0x0001..0xFFFF do
    %__MODULE__{identifier: identifier}
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise311.Encodable do
    def encode(%Package.Pubrec{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [Package.Meta.encode(t.__META__), <<2, t.identifier::big-integer-size(16)>>]
    end
  end
end
