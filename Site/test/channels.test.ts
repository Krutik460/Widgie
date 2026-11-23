import { describe, expect, it } from "vitest";
import { channelOf, touchOf } from "../public/channels.js";

const OWN = "widgie.krutikpatel.dev";

describe("channelOf", () => {
    it.each([
        ["t.co", "x"],
        ["x.com", "x"],
        ["com.twitter.android", "x"],
        ["old.reddit.com", "reddit"],
        ["out.reddit.com", "reddit"],
        ["com.reddit.frontpage", "reddit"],
        ["www.producthunt.com", "producthunt"],
        ["news.ycombinator.com", "hn"],
        ["lnkd.in", "linkedin"],
        ["l.instagram.com", "instagram"],
        ["www.google.com", "google"],
        ["www.google.co.uk", "google"],
        ["mail.google.com", "email"],
        ["com.google.android.gm", "email"],
        ["outlook.live.com", "email"],
        ["docs.google.com", "docs.google.com"],
        ["www.someblog.com", "someblog.com"],
    ])("%s is %s", (host, channel) => {
        expect(channelOf(host)).toBe(channel);
    });
});

describe("touchOf", () => {
    it("prefers the link's tags, and fills the medium from the source", () => {
        expect(touchOf("?utm_source=Reddit&utm_content=longdistance", "https://www.reddit.com/r/x", OWN)).toEqual({
            first_source: "reddit",
            first_medium: "community",
            first_campaign: null,
            first_content: "longdistance",
            first_referrer: "www.reddit.com",
        });
    });

    it("counts Product Hunt's own ?ref", () => {
        expect(touchOf("?ref=producthunt", "", OWN)).toMatchObject({
            first_source: "producthunt",
            first_medium: "launch",
        });
    });

    it("names an untagged referrer, and calls an unknown site a referral", () => {
        expect(touchOf("", "https://t.co/abc", OWN)).toMatchObject({ first_source: "x", first_medium: "social" });
        expect(touchOf("", "https://blog.example.com/post", OWN)).toMatchObject({
            first_source: "blog.example.com",
            first_medium: "referral",
        });
    });

    it("credits an email client to email, not search", () => {
        expect(touchOf("", "android-app://com.google.android.gm/", OWN)).toMatchObject({
            first_source: "email",
            first_medium: "email",
        });
    });

    it("is null for a direct visit, a move between our own pages, or a broken referrer", () => {
        expect(touchOf("", "", OWN)).toBeNull();
        expect(touchOf("", `https://${OWN}/partners`, OWN)).toBeNull();
        expect(touchOf("", "not a url", OWN)).toBeNull();
    });
});
