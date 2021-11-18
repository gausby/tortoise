defmodule Tortoise311.Package do
  @moduledoc false

  alias Tortoise311.Package

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

  defdelegate encode(data), to: Tortoise311.Encodable
  defdelegate decode(data), to: Tortoise311.Decodable

  @doc false
  def length_encode(data) do
    length_prefix = <<byte_size(data)::big-integer-size(16)>>
    [length_prefix, data]
  end

  @doc false
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
