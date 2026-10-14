# tern-bigquery

`tern-bigquery` adds a BigQuery browser to [Tern](https://docs.stencil.so/tern/).
The browser is a native block, which is a pane in a Tern session.
It uses the BigQuery command-line tool, `bq`, to read data.

## Functions

The browser can show these resources:

- Google Cloud projects.
- BigQuery datasets.
- Tables and views.
- Table properties and schema fields.
- Table data, with 50 rows on each preview page.

The schema grid shows all fields, including nested fields.
The grid has four columns: Field, Type, Mode, and Description.
Long field names and descriptions can use more than one line.

The preview grid keeps all columns in schema order.
It also shows fields that occur only in the returned data.
Missing values show as `NULL`.
Nested values show as JSON text.
Both grids have horizontal and vertical scroll controls.

The browser can copy a table name, a SQL example, or the current preview page as JSON.
It saves the selected project when the block stops.
It does not save credentials or preview data in the block state.

## Requirements

Install these programs on the machine that runs the pane:

- Tern, with support for plugin blocks and native text fields.
- Google Cloud CLI, including `bq` and `gcloud`.
- A Python version that your Google Cloud CLI supports.

Use a Google Cloud account with permission to read the required resources.
A remote pane needs these programs and account credentials on the remote machine.

## Installation

1. Open a shell on the machine that runs the pane.
2. Sign in to Google Cloud:

   ```sh
   gcloud auth login
   ```

3. Make sure that BigQuery access works:

   ```sh
   bq ls
   ```

4. Install the plugin:

   ```sh
   tern plugin install github.com/junaidrahim/tern-bigquery
   ```

5. Open the Tern command palette.
6. Select **New BigQuery block**.

For work on the source code, link the local repository instead:

```sh
cd tern-bigquery
tern plugin link .
```

## Use the browser

### Open a resource

1. Click a row to select a resource.
2. Click **Open selected**.

A double-click on a row also opens the resource.
The resource path at the top contains buttons for earlier levels.

### Open a project by ID

1. Click **Open project…**.
2. Enter the project ID.
3. Click **Open**.

Use this procedure if the project does not occur in the project list.
Click **Cancel** to close the project form.

### Find a resource

1. Click the search field.
2. Enter one or more search terms.

The list changes as you enter text.
The search uses resource IDs, names, and types.
It ignores letter case.
All search terms must match.
The count shows the number of matches and the number of loaded resources.

Click **Clear** to remove the search terms.
The browser also clears the search terms when you open another level.

### Read the schema

1. Open a table or view.
2. Select the **Schema** tab.
3. Scroll horizontally to see all four columns.
4. Scroll vertically to see more fields.

### Read the preview

1. Open a table.
2. Select the **Preview** tab.
3. Scroll horizontally to see more columns.
4. Click a row number to open the row inspector.

The row inspector shows the complete value of each field.
Click **Close inspector** to close it.

Click **Next** or **Previous** to change the preview page.
Click **Copy page JSON** to copy the current page.
BigQuery does not guarantee the row order in a preview.

## Keyboard controls

| Key | Function |
| --- | --- |
| Up / Down or j / k | Select a resource. |
| Enter | Open the selected resource. |
| Esc | Return to the previous level. |
| / | Put the cursor in the search field. |
| p | Open the project form. |
| r | Refresh the current screen. |
| v | Open the preview from the schema screen. |
| y | Copy the table name from a detail screen. |

In a text field, Enter accepts the text.
Esc closes the field and clears an active search.
Ctrl+U clears the text.
Cmd+A or Ctrl+A selects all text.

## Configuration

The plugin uses the account and configuration of Google Cloud CLI.
It checks common Homebrew paths for `bq` and `gcloud`.

For another installation path, set `TERN_BIGQUERY_BQ` to the absolute path of `bq`.
Set the variable in the Tern host environment before you start Tern.
The plugin adds the directory of `bq` to its subprocess `PATH`.
This lets `bq` find `gcloud` for authentication.

If `CLOUDSDK_PYTHON` has no value, the plugin checks common Homebrew paths for Python 3.11–3.14.
It does not replace an existing value of `CLOUDSDK_PYTHON`.

## Problems

| Problem | Action |
| --- | --- |
| Expired credentials | Run `gcloud auth login` in a shell. Then click **Refresh**. |
| Missing `bq` | Install Google Cloud CLI on the pane host. |
| Missing `gcloud` | Make sure that `gcloud` is in the same directory as `bq`, or in the host `PATH`. |
| Python error | Set `CLOUDSDK_PYTHON` to a Python interpreter that your Google Cloud CLI supports. |
| Request timeout | Click **Refresh** to try again. |
| Missing project | Use **Open project…** to enter its ID. |

Each request has a 30-second timeout.

## Limits

- Dataset and table lists request a maximum of 1,000 resources.
- Search applies only to loaded resources.
- A view has a schema, but `bq head` cannot show its data.
- The browser does not run SQL queries.
- The browser does not yet have favorites or more pages for resource lists.

## Development

1. Generate the type definitions for your Tern version:

   ```sh
   tern plugin types .
   ```

2. Run the tests with a Luau interpreter:

   ```sh
   LUAU=/path/to/luau python3 tests/run.py
   ```

The tests use the production block with a simulated Tern environment.
They check navigation, search, text changes, command arguments, and errors.
They also check all schema columns, wide previews, null values, and nested fields.
The tests do not connect to Google Cloud.

## Planned functions

- Favorites and more pages for resource lists.
- More table properties, including partition and clustering data.
- A SQL editor with dry runs, a byte limit, and query job controls.
- Local SQL files and selected schema data for agents.

## References

- [Tern Plugin SDK](https://docs.stencil.so/tern/).
- [Tern SDK source](https://github.com/stencil-hq/tern-sdk).
- [BigQuery CLI reference](https://docs.cloud.google.com/bigquery/docs/reference/bq-cli-reference).
