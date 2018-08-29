defmodule Tortoise.Package.Pubcomp do
  @moduledoc false

  @opcode 7

  alias Tortoise.Package

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: Tortoise.package_identifier()
          }
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            identifier: nil

  @spec decode(<<_::32>>) :: __MODULE__.t()
  def decode(<<@opcode::4, 0::4, 2, identifier::big-integer-size(16)>>)
      when identifier in 0x0001..0xFFFF do
    %__MODULE__{identifier: identifier}
  end

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    def encode(%Package.Pubcomp{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [Package.Meta.encode(t.__META__), <<2, t.identifier::big-integer-size(16)>>]
    end
  end
end
