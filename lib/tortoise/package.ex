defmodule Tortoise.Package do
  alias Tortoise.Package

  @opaque message ::
            Package.Connect.t()
            | Package.Connack.t()
            | Package.Publish.t()
            | Package.Puback.t()
            | Package.Pubrec.t()
            | Package.Pubrel.t()
            | Package.Pubcomp.t()
            | Package.Subscribe.t()
            | Package.Suback.t()
            | Package.Unsubscribe.t()
            | Package.Unsuback.t()
            | Package.Pingreq.t()
            | Package.Pingresp.t()
            | Package.Disconnect.t()

  defdelegate encode(data), to: Tortoise.Encodable
  defdelegate decode(data), to: Tortoise.Decodable

  def generate_random_identifier() do
    <<identifier::big-integer-size(16)>> = :crypto.strong_rand_bytes(2)
    identifier
  end

  def length_encode(data) do
    length_prefix = <<byte_size(data)::big-integer-size(16)>>
    [length_prefix, data]
  end

  def variable_length_encode(data) when is_list(data) do
    length_prefix = data |> IO.iodata_length() |> remaining_length()
    length_prefix ++ data
  end

  @highbit 0b10000000
  defp remaining_length(n) when n < @highbit, do: [<<0::1, n::7>>]

  defp remaining_length(n) do
    [<<1::1, rem(n, @highbit)::7>>] ++ remaining_length(div(n, @highbit))
  end
end
