defmodule Tortoise.Package.Connack do
  @moduledoc false

  @opcode 2

  alias Tortoise.Package

  @type status :: :accepted | {:refused, refusal_reasons()}
  @type refusal_reasons ::
          :unacceptable_protocol_version
          | :identifier_rejected
          | :server_unavailable
          | :bad_user_name_or_password
          | :not_authorized

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            session_present: boolean(),
            status: status() | nil
          }
  @enforce_keys [:status]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            session_present: false,
            status: nil

  def decode(<<@opcode::4, 0::4, 2, 0::7, session_present::1, return_code::8>>) do
    %__MODULE__{
      session_present: session_present == 1,
      status: coerce_return_code(return_code)
    }
  end

  defp coerce_return_code(return_code) do
    case return_code do
      0x00 -> :accepted
      0x01 -> {:refused, :unacceptable_protocol_version}
      0x02 -> {:refused, :identifier_rejected}
      0x03 -> {:refused, :server_unavailable}
      0x04 -> {:refused, :bad_user_name_or_password}
      0x05 -> {:refused, :not_authorized}
    end
  end

  defimpl Tortoise.Encodable do
    def encode(%Package.Connack{session_present: session_present, status: status} = t)
        when status != nil do
      [
        Package.Meta.encode(t.__META__),
        <<2, 0::7, flag(session_present)::1, to_return_code(status)::8>>
      ]
    end

    defp to_return_code(:accepted), do: 0x00

    defp to_return_code({:refused, reason}) do
      case reason do
        :unacceptable_protocol_version -> 0x01
        :identifier_rejected -> 0x02
        :server_unavailable -> 0x03
        :bad_user_name_or_password -> 0x04
        :not_authorized -> 0x05
      end
    end

    defp flag(f) when f in [0, nil, false], do: 0
    defp flag(_), do: 1
  end
end
