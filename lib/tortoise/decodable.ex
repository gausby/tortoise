defprotocol Tortoise.Decodable do
  def decode(data)
end

defimpl Tortoise.Decodable, for: BitString do
  alias Tortoise.Package.{
    Connect,
    Connack,
    Publish,
    Puback,
    Pubrec,
    Pubrel,
    Pubcomp,
    Subscribe,
    Suback,
    Unsubscribe,
    Unsuback,
    Pingreq,
    Pingresp,
    Disconnect
  }

  def decode(<<1::4, _::4, _::binary>> = data), do: Connect.decode(data)
  def decode(<<2::4, _::4, _::binary>> = data), do: Connack.decode(data)
  def decode(<<3::4, _::4, _::binary>> = data), do: Publish.decode(data)
  def decode(<<4::4, _::4, _::binary>> = data), do: Puback.decode(data)
  def decode(<<5::4, _::4, _::binary>> = data), do: Pubrec.decode(data)
  def decode(<<6::4, _::4, _::binary>> = data), do: Pubrel.decode(data)
  def decode(<<7::4, _::4, _::binary>> = data), do: Pubcomp.decode(data)
  def decode(<<8::4, _::4, _::binary>> = data), do: Subscribe.decode(data)
  def decode(<<9::4, _::4, _::binary>> = data), do: Suback.decode(data)
  def decode(<<10::4, _::4, _::binary>> = data), do: Unsubscribe.decode(data)
  def decode(<<11::4, _::4, _::binary>> = data), do: Unsuback.decode(data)
  def decode(<<12::4, _::4, _::binary>> = data), do: Pingreq.decode(data)
  def decode(<<13::4, _::4, _::binary>> = data), do: Pingresp.decode(data)
  def decode(<<14::4, _::4, _::binary>> = data), do: Disconnect.decode(data)
end

defimpl Tortoise.Decodable, for: List do
  def decode(data) do
    data
    |> IO.iodata_to_binary()
    |> Tortoise.Decodable.decode()
  end
end
