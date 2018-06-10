defmodule Tortoise.Registry do
  @moduledoc false

  @type client_id :: pid() | binary()
  @type via :: {:via, Registry, {__MODULE__, {atom(), client_id()}}}

  @spec via_name(atom(), client_id()) :: via() | pid()
  def via_name(_module, client_id) when is_pid(client_id), do: client_id

  def via_name(module, client_id) do
    {:via, Registry, reg_name(module, client_id)}
  end

  defp reg_name(module, client_id) do
    {__MODULE__, {module, client_id}}
  end
end
