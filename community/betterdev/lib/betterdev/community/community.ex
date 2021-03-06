defmodule Betterdev.Community do
  @moduledoc """
  The boundary for the Community system.
  """

  import Ecto.Query, warn: false
  alias Betterdev.Repo

  alias Betterdev.Community.Link
  alias Betterdev.Community.Tag
  alias Betterdev.Community.Collection

  import Tirexs.HTTP
	import Tirexs.Search
	alias Tirexs.Search

  @doc """
  Returns the list of links.

  ## Examples

      iex> list_links()
      [%Link{}, ...]

  """
  def list_links(params \\ %{}) do
    collection_query = from c in Collection, where: c.user_id == 3
    link = from p in Link,
      order_by: [desc: :id],
      preload: [:tags, :user, collections: ^collection_query]
      #link = Repo.preload(link, [collections: ^collection_query])

    if params["q"] do
      link_ids = search_links(params["q"])
      link = from p in link,
        where: p.id in ^(link_ids)
    end

    link = case params do
      %{"user_id" => uid} ->
        from p in link,
          where: p.user_id == ^(uid)
      %{"collection" => collection_id} ->
        from p in link,
          #preload: [:collections],
          left_join: lc in "community_collection_links", on: lc.link_id == p.id,
          where: lc.collection_id == ^(collection_id)
      _ -> link
    end

    link |> Repo.paginate(params)
  end

  def search_links(q) do
		query = Search.search [index: "betterdev"] do
			query do
				match "_all", q
			end
		end

		case Tirexs.Query.create_resource(query) do
			{:ok, status, %{hits: %{hits: hits}}} -> Enum.map(hits, &(&1._source.id))
			_ -> []
		end
	end

  @doc """
  Gets a single link.

  Raises `Ecto.NoResultsError` if the Link does not exist.

  ## Examples

      iex> get_link!(123)
      %Link{}

      iex> get_link!(456)
      ** (Ecto.NoResultsError)

  """
  def get_link!(id) do
    link = Repo.preload(Link, :user)
    Repo.get!(link, id)
  end

  @doc """
  Creates a link.

  ## Examples

      iex> create_link(%{field: value})
      {:ok, %Link{}}

      iex> create_link(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
   ## %Link{user_id: 1, title: w.title || url, uri: url, description: w.description, picture: w.image || w.favicon, status: "published", } |> Repo.insert()
  def create_link(attrs \\ %{}) do
    %Link{}
    |> Link.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a link with uri only. We will parse title, description from the link
  """
  def user_post_link(user, attrs) do
    # TODO Use task/job queue and return to client instantly via web socket
    uri = attrs["uri"]
    w = Readability.summarize(uri)
    if w.title do
      #%{user: user, title: w.title || url, uri: url, description: w.description, picture: w.image || w.favicon, status: "published", } |> Repo.insert()
      {:ok, link} = %Link{user: user}
        |> Link.changeset(%{title: w.title, uri: uri, description: w.article_text, picture: w.top_image, status: "published"})
        |> Repo.insert()
      Task.start_link(fn -> post_process_link(link, w) end)
      link = link |> Repo.preload(:tags) |> Repo.preload(:collections)
      {:ok, link}
    end
  end

  @doc """
  Post processing once a link is submited.

  We will:
   - index to elasticsearch
   - process tag
  """
  def post_process_link(link, w) do
    IO.puts "Post process link"

    #body = case HTTPoison.get(link.uri,  [], [ ssl: [{:versions, [:'tlsv1.2']}] ]) do
    #  {:ok,  %HTTPoison.Response{body: b}} -> HtmlSanitizeEx.strip_tags(b)
    #_ -> w.fulltext
    #end

    r = [id: link.id, title: w.title, description: w.article_text, content: w.article_text, uri: link.uri]

    # index
    put("/betterdev/link/#{link.id}", r)

    tags = Betterdev.Helper.Classifier.extract(w.article_text)
    # Insert tag
    link = link |> Repo.preload(:tags) |> Repo.preload(:user)
    tags = tags ++ (w.tags |> Enum.filter_map(&(&1[:accuracy] >= 0.7), &(&1[:name])))
    tags |> Enum.map(fn (title) ->
      t = retreive_tag(title)
      # http://blog.roundingpegs.com/an-example-of-many-to-many-associations-in-ecto-and-phoenix/
      # We need preload to preapre for changset below
      t = t |> Repo.preload(:links)
      try do
        changeset = Ecto.Changeset.change(link) |> Ecto.Changeset.put_assoc(:tags, [t])
        Repo.update!(changeset)
      rescue
        e in RuntimeError -> e
      end
    end)
  end

  def retreive_tag(t) when is_atom(t), do: retreive_tag(to_string(t))
  def retreive_tag(t)  do
    case Repo.get_by(Tag, title: t) do
      nil -> %Tag{title: t, type: "autogen"} |> Repo.insert!()
      tag -> tag
    end
  end

  @doc """
  Updates a link.

  ## Examples

      iex> update_link(link, %{field: new_value})
      {:ok, %Link{}}

      iex> update_link(link, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_link(%Link{} = link, attrs) do
    link
    |> Link.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Link.

  ## Examples

      iex> delete_link(link)
      {:ok, %Link{}}

      iex> delete_link(link)
      {:error, %Ecto.Changeset{}}

  """
  def delete_link(%Link{} = link) do
    Repo.delete(link)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking link changes.

  ## Examples

      iex> change_link(link)
      %Ecto.Changeset{source: %Link{}}

  """
  def change_link(%Link{} = link) do
    Link.changeset(link, %{})
  end

  alias Betterdev.Community.Collection

  @doc """
  Returns the list of collections.

  ## Examples

      iex> list_collections()
      [%Collection{}, ...]

  """
  def list_collections(user) do
    collection = from c in Collection,
                  where: c.user_id == ^(user.id),
                  order_by: [desc: c.id],
                  select: [:id, :name]
    Repo.all(collection)
  end

  @doc """
  Gets a single collection.

  Raises `Ecto.NoResultsError` if the Collection does not exist.

  ## Examples

      iex> get_collection!(123)
      %Collection{}

      iex> get_collection!(456)
      ** (Ecto.NoResultsError)

  """
  def get_collection!(id), do: Repo.get!(Collection, id)

  @doc """
  Creates a collection.

  ## Examples

      iex> create_collection(%{field: value})
      {:ok, %Collection{}}

      iex> create_collection(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_collection(user, attrs \\ %{}) do
    %Collection{user: user}
    |> Collection.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a collection.

  ## Examples

      iex> update_collection(collection, %{field: new_value})
      {:ok, %Collection{}}

      iex> update_collection(collection, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_collection(%Collection{} = collection, attrs) do
    collection
    |> Collection.changeset(attrs)
    |> Repo.update()
  end

  def add_link_to_collection(user, collection_id, link_id) do
    # Fix n+1 issue
    collection_query = from c in Collection, where: c.user_id == ^(user.id)
    link = from l in Link,
              preload: [:user, :collections]
    link = Repo.get!(link, link_id)
    #link |> Repo.preload(link, [collections: ^collection_query])

    IO.inspect link
    link = link |> Repo.preload(:collections)

    collection = Repo.get!(from(c in Collection, preload: [:links, :user]), collection_id)

    changeset = Ecto.Changeset.change(collection) |> Ecto.Changeset.put_assoc(:links, [link])
    changeset |> Repo.update

    {:ok, collection}
  end


  @doc """
  Deletes a Collection.

  ## Examples

      iex> delete_collection(collection)
      {:ok, %Collection{}}

      iex> delete_collection(collection)
      {:error, %Ecto.Changeset{}}

  """
  def delete_collection(%Collection{} = collection) do
    Repo.delete(collection)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking collection changes.

  ## Examples

      iex> change_collection(collection)
      %Ecto.Changeset{source: %Collection{}}

  """
  def change_collection(%Collection{} = collection) do
    Collection.changeset(collection, %{})
  end
end
