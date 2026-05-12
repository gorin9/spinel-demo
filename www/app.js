console.log("hello from spinel httpd");
const t = new Date().toISOString();
document.body && (document.body.innerHTML += "<p>loaded at " + t + "</p>");
