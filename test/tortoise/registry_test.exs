defmodule Tortoise.RegistryTest do
  use ExUnit.Case, async: true
  doctest Tortoise.Registry

  test "via_name/2", context do
    {mod, name} = {__MODULE__, context.test}

    assert {:via, Registry, {Tortoise.Registry, {^mod, ^name}}} =
             Tortoise.Registry.via_name(mod, name)
  end

  test "meta put, get, delete", context do
    key = Tortoise.Registry.via_name(__MODULE__, context.test)
    value = :crypto.strong_rand_bytes(2)

    assert :error == Tortoise.Registry.meta(key)
    assert :ok = Tortoise.Registry.put_meta(key, value)
    assert {:ok, ^value} = Tortoise.Registry.meta(key)
    assert :ok = Tortoise.Registry.delete_meta(key)
    assert :error == Tortoise.Registry.meta(key)
  end
end
