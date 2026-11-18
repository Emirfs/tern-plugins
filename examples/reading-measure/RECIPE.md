# Reading Measure

In the **Reader** chat style, Markdown paragraphs, headings, lists and quotations stop at 72 CSS `ch`. Code fences, tables and the composer keep their native widths. On narrow panes, prose already fits below that limit and is not made wider.

```sh
tern plugin install github.com/Emirfs/tern-plugins/examples/reading-measure
```

Open a wide agent pane with Tern's Reader chat style and an answer containing a long paragraph, a table and a code fence. Resize the pane to see the paragraph wrap without imposing the same measure on the table or code.

To remove it: `tern plugin remove reading-measure`.
