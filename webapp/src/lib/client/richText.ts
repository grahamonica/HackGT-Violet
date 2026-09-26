"use client";

const ALLOWED_TAGS = new Set(["B", "STRONG", "I", "EM", "U", "UL", "OL", "LI", "BR", "P", "DIV"]);

// Some browsers emit <span style="font-weight: bold"> instead of <b>. Map those styles to tags before dropping attributes.
function styleTags(element: Element): string[] {
  const style = (element as HTMLElement).style;
  if (!style) return [];
  const tags: string[] = [];
  const weight = style.fontWeight;
  if (weight === "bold" || weight === "bolder" || Number(weight) >= 600) tags.push("b");
  if (style.fontStyle === "italic" || style.fontStyle === "oblique") tags.push("i");
  if (`${style.textDecoration} ${style.textDecorationLine}`.includes("underline")) tags.push("u");
  return tags;
}

function cleanNode(node: Node, output: Node, document: Document): void {
  for (const child of Array.from(node.childNodes)) {
    if (child.nodeType === Node.TEXT_NODE) {
      output.appendChild(document.createTextNode(child.textContent ?? ""));
    } else if (child.nodeType === Node.ELEMENT_NODE) {
      const element = child as Element;
      const wrappers = ALLOWED_TAGS.has(element.tagName) ? [] : styleTags(element);
      if (wrappers.length) {
        let target: Node = output;
        for (const tag of wrappers) target = target.appendChild(document.createElement(tag));
        cleanNode(element, target, document);
      } else if (ALLOWED_TAGS.has(element.tagName)) {
        const clean = document.createElement(element.tagName.toLowerCase());
        cleanNode(element, clean, document);
        output.appendChild(clean);
      } else {
        cleanNode(element, output, document);
      }
    }
  }
}

// Keeps only basic formatting tags and drops every attribute, so stored notes cannot carry scripts or styles.
export function sanitizeHtml(html: string): string {
  if (typeof window === "undefined") return "";
  const parsed = new DOMParser().parseFromString(html, "text/html");
  const container = parsed.createElement("div");
  cleanNode(parsed.body, container, parsed);
  return container.innerHTML;
}

export function plainText(html: string): string {
  if (typeof window === "undefined") return "";
  return new DOMParser().parseFromString(html, "text/html").body.textContent?.trim() ?? "";
}
