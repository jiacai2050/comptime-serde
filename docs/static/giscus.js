function appendGiscusScript() {
  const pageDiv = document.querySelector('#mdbook-content > main');

  if (!pageDiv) {
    console.error('Could not find div with class "page"');
    return;
  }
  const commentsDiv = document.createElement('div');
  commentsDiv.className = 'giscus';
  pageDiv.appendChild(commentsDiv);

  const script = document.createElement('script');
  script.src = "https://giscus.app/client.js";
  script.setAttribute("data-repo", "jiacai2050/comptime-serde");
  script.setAttribute("data-repo-id", "R_kgDOSXx0pQ");
  script.setAttribute("data-category", "Q&A");
  script.setAttribute("data-category-id", "DIC_kwDOSXx0pc4C8sVY");
  script.setAttribute("data-mapping", "pathname");
  script.setAttribute("data-strict", "1");
  script.setAttribute("data-reactions-enabled", "1");
  script.setAttribute("data-emit-metadata", "0");
  script.setAttribute("data-input-position", "bottom");
  script.setAttribute("data-theme", "preferred_color_scheme");
  script.setAttribute("data-lang", "en");
  script.setAttribute("crossorigin", "anonymous");
  script.async = true;
  pageDiv.appendChild(script);
}

document.addEventListener('DOMContentLoaded', appendGiscusScript);
