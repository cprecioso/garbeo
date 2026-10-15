// Runs grammars for WebHighlighter.swift, in a WebPage that's never shown.
import { Language, Parser, Query } from './web-tree-sitter.js';

const ready = Parser.init();
const grammars = new Map();

window.garbeoSyntax = {
  // Loads a grammar's wasm (served by the page's scheme handler) and compiles its queries.
  async load(name, wasmURL, highlights, injections) {
    await ready;
    const language = await Language.load(wasmURL);
    const parser = new Parser();
    parser.setLanguage(language);
    grammars.set(name, {
      parser,
      highlights: new Query(language, highlights),
      injections: injections.trim() ? new Query(language, injections) : null,
    });
  },

  // Parses `code` (only `ranges` of it, if given) and returns every capture as [start, end, name, pattern] (UTF-16
  // offsets, an index into `names`, the pattern's index), flattened into one array, plus the ranges injected
  // languages cover. Null if the grammar isn't loaded (the page was reloaded).
  highlight(name, code, ranges) {
    const grammar = grammars.get(name);
    if (!grammar) return null;
    const tree = grammar.parser.parse(code, null, ranges ? { includedRanges: ranges } : undefined);
    try {
      const names = [], indices = new Map(), captures = [];
      for (const capture of grammar.highlights.captures(tree.rootNode)) {
        let index = indices.get(capture.name);
        if (index === undefined) {
          index = names.push(capture.name) - 1;
          indices.set(capture.name, index);
        }
        captures.push(capture.node.startIndex, capture.node.endIndex, index, capture.patternIndex);
      }
      return { names, captures, injections: grammar.injections ? injections(grammar.injections, tree) : [] };
    } finally {
      tree.delete();
    }
  },
};

// Injected languages and their ranges. A language is named by an `injection.language` capture's text or set with
// `#set!`; every `injection.content` node in it goes into one layer, as SwiftTreeSitterLayer does.
function injections(query, tree) {
  const layers = new Map();
  for (const match of query.matches(tree.rootNode)) {
    const content = match.captures.find((capture) => capture.name === 'injection.content')?.node;
    const named = match.captures.find((capture) => capture.name === 'injection.language')?.node;
    const language = named?.text ?? match.setProperties?.['injection.language'];
    if (!content || !language || content.startIndex === content.endIndex) continue;
    const { startIndex, endIndex, startPosition, endPosition } = content;
    if (!layers.has(language)) layers.set(language, []);
    layers.get(language).push({ startIndex, endIndex, startPosition, endPosition });
  }
  return [...layers].map(([language, ranges]) => ({ language, ranges: disjoint(ranges) }));
}

// Included ranges must be sorted and can't overlap: a range inside an earlier one is dropped.
function disjoint(ranges) {
  ranges.sort((a, b) => a.startIndex - b.startIndex);
  let end = 0;
  return ranges.filter((range) => {
    if (range.startIndex < end) return false;
    end = range.endIndex;
    return true;
  });
}
