// The two emails the waitlist sends, through Resend. Plain HTML that renders in any client, plus a text part.

/// "partners" and "growth" are the audiences; "home" and "us" remain on rows made before they were merged and split.
export type Segment = "partners" | "growth" | "home" | "us";

export interface Mail {
    to: string;
    subject: string;
    html: string;
    text: string;
    /// The one-click removal endpoint, sent as List-Unsubscribe so mail clients can show their own button.
    unsubscribeUrl: string;
}

export class MailFailure extends Error {}

export async function send(env: Cloudflare.Env, fetcher: typeof fetch, mail: Mail): Promise<void> {
    if (!env.RESEND_API_KEY) throw new MailFailure("RESEND_API_KEY is not set");
    // Local development only (.dev.vars): print the mail instead of sending it, so the flow can be clicked through.
    if (env.RESEND_API_KEY === "log") {
        console.log(`[mail to ${mail.to}] ${mail.subject}\n${mail.text}`);
        return;
    }
    const response = await fetcher("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({
            from: env.EMAIL_FROM,
            to: [mail.to],
            reply_to: env.REPLY_TO,
            subject: mail.subject,
            html: mail.html,
            text: mail.text,
            headers: {
                "List-Unsubscribe": `<${mail.unsubscribeUrl}>`,
                "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
            },
        }),
    });
    if (!response.ok) throw new MailFailure(`resend answered ${response.status}`);
}

const WHO: Record<Segment, string> = {
    partners: "your partner",
    growth: "a friend who keeps you going",
    home: "your home",
    us: "your partner",
};

/// Where a person removes themselves: a page with a button (`page`) and the endpoint mail clients post to (`oneClick`).
export interface Leave {
    page: string;
    oneClick: string;
}

/// `joining` is true for someone who came through another person's invite link.
export function confirmMail(to: string, segment: Segment, joining: boolean, confirmUrl: string, leave: Leave): Mail {
    const lines = [
        "One tap to hold your spot on the Widgie early list.",
        joining
            ? "That puts you in the same group as the person who invited you, so you get in together."
            : `After that you get a link to share with ${WHO[segment]}, so you get in together.`,
    ];
    return {
        to,
        subject: "Confirm your spot on the Widgie list",
        text: `${lines.join("\n\n")}\n\nConfirm: ${confirmUrl}\n\nNot you? Ignore this email, or remove it from the list: ${leave.page}\n`,
        html: page(lines, { label: "Confirm my spot", url: confirmUrl }, leave.page),
        unsubscribeUrl: leave.oneClick,
    };
}

export function alreadyInMail(to: string, segment: Segment, shareUrl: string, leave: Leave): Mail {
    const lines = [
        "You're already on the Widgie early list.",
        `Here is your link again. Send it to ${WHO[segment]}: when they join, you get in together.`,
    ];
    return {
        to,
        subject: "Your Widgie link",
        text: `${lines.join("\n\n")}\n\n${shareUrl}\n\nRemove me from the list: ${leave.page}\n`,
        html: page(lines, { label: "Open my link", url: shareUrl }, leave.page),
        unsubscribeUrl: leave.oneClick,
    };
}

function escapeHtml(text: string): string {
    return text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function page(lines: string[], button: { label: string; url: string }, leaveUrl: string): string {
    const paragraphs = lines
        .map(
            (line) => `<p style="margin:0 0 16px;font-size:17px;line-height:1.5;color:#121A2E">${escapeHtml(line)}</p>`,
        )
        .join("");
    return `<!doctype html><html><body style="margin:0;padding:32px 16px;background:#C4D8F3;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif">
<div style="max-width:480px;margin:0 auto">
<p style="margin:0 0 28px;font-size:24px;font-weight:800;letter-spacing:-0.5px;color:#121A2E">widgie<span style="display:inline-block;width:4px;height:22px;margin-left:5px;vertical-align:-3px;background:#121A2E;border-radius:2px"></span></p>
${paragraphs}
<p style="margin:28px 0"><a href="${escapeHtml(button.url)}" style="display:inline-block;padding:16px 28px;border-radius:14px;background:#121A2E;color:#C4D8F3;font-size:17px;font-weight:700;text-decoration:none">${escapeHtml(button.label)}</a></p>
<p style="margin:40px 0 0;font-size:13px;line-height:1.5;color:#3E4C6B">Widgie is being built in public by Krutik. <a href="${escapeHtml(leaveUrl)}" style="color:#3E4C6B">Remove me from the list</a>.</p>
</div></body></html>`;
}
