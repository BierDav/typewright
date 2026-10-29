import type { CodeEditor, monaco } from "./monaco";
import { selectionShape } from "./selectionShape";

/** Uses Monaco's laid-out rectangles, so wrapping, folding and concealed text keep their geometry. */
export function connectedSelection(editor: CodeEditor): monaco.IDisposable {
  const host = editor.getContainerDomNode();
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  const path = document.createElementNS(svg.namespaceURI, "path");
  svg.classList.add("tw-selection-shape");
  svg.append(path);
  host.classList.add("tw-connected-selection");
  let frame = 0;
  function draw() {
    frame = 0;
    const content = host.querySelector<HTMLElement>(".lines-content");
    if (!content) return;
    if (svg.parentElement !== content) content.insertBefore(svg, content.querySelector(".view-lines"));
    svg.style.width = `${host.clientWidth + editor.getScrollLeft()}px`;
    svg.style.height = `${host.clientHeight + editor.getScrollTop()}px`;
    const origin = content.getBoundingClientRect();
    const boxes = [...host.querySelectorAll<HTMLElement>(".selected-text")].map((node) => {
      const box = node.getBoundingClientRect();
      return { x: box.left - origin.left, y: box.top - origin.top, width: box.width, height: box.height };
    });
    const shape = selectionShape(boxes);
    if (path.getAttribute("d") !== shape) path.setAttribute("d", shape);
  }
  const schedule = () => { frame ||= requestAnimationFrame(draw); };
  const observer = new MutationObserver((records) => {
    if (records.some((r) => r.target !== svg && r.target !== path)) schedule();
  });
  observer.observe(host, { childList: true, subtree: true, attributes: true });
  const listeners = [editor.onDidChangeCursorSelection(schedule), editor.onDidScrollChange(schedule), editor.onDidLayoutChange(schedule)];
  schedule();
  return { dispose() { observer.disconnect(); listeners.forEach((l) => l.dispose()); cancelAnimationFrame(frame); svg.remove(); host.classList.remove("tw-connected-selection"); } };
}
