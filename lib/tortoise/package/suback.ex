defmodule Tortoise.Package.Suback do
  @opcode 9

  alias Tortoise.Package

  @type package_identifier :: 0x0001..0xFFFF
  @type qos :: 0 | 1 | 2
  @type ack_result :: {:ok, qos} | {:error, :access_denied}

  @opaque t :: %__MODULE__{
            __META__: Package.Meta.t(),
            identifier: package_identifier() | nil,
            acks: [ack_result]
          }
  @enforce_keys [:identifier]
  defstruct __META__: %Package.Meta{opcode: @opcode, flags: 0},
            identifier: nil,
            acks: []

  @spec decode(binary()) :: t
  def decode(<<@opcode::4, 0::4, payload::binary>>) do
    with payload <- drop_length(payload),
         <<identifier::big-integer-size(16), acks::binary>> <- payload,
         acks <- return_codes_to_list(acks),
         do: %__MODULE__{identifier: identifier, acks: acks}
  end

  defp drop_length(payload) do
    case payload do
      <<0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
      <<1::1, _::7, 1::1, _::7, 1::1, _::7, 0::1, _::7, r::binary>> -> r
    end
  end

  defp return_codes_to_list(<<>>), do: []

  defp return_codes_to_list(<<0x80::integer, acks::binary>>),
    do: [{:error, :access_denied}] ++ return_codes_to_list(acks)

  defp return_codes_to_list(<<ack::integer, acks::binary>>) when ack in 0x00..0x02,
    do: [{:ok, ack}] ++ return_codes_to_list(acks)

  # Protocols ----------------------------------------------------------
  defimpl Tortoise.Encodable do
    @spec encode(Package.Suback.t()) :: iodata()
    def encode(%Package.Suback{identifier: identifier} = t)
        when identifier in 0x0001..0xFFFF do
      [
        Package.Meta.encode(t.__META__),
        Package.variable_length_encode([
          <<identifier::big-integer-size(16)>>,
          Enum.map(t.acks, &encode_ack/1)
        ])
      ]
    end

    defp encode_ack({:ok, qos}) when qos in 0x00..0x02, do: qos
    defp encode_ack({:error, _}), do: 0x80
  end
end
