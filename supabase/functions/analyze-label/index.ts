import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
}

interface AnalyzeRequest {
  photoBase64: string
  latitude: number | null
  longitude: number | null
}

interface LabelData {
  epa_registration_number: string | null
  product_name: string | null
  manufacturer: string | null
  signal_word: string | null
  active_ingredients: { name: string; concentration: string }[] | null
  precautionary_statements: string[] | null
  first_aid: {
    eyes: string | null
    skin: string | null
    ingestion: string | null
    inhalation: string | null
  } | null
  storage_and_disposal: string | null
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  try {
    const { photoBase64, latitude, longitude }: AnalyzeRequest =
      await req.json()

    if (!photoBase64) {
      return new Response(
        JSON.stringify({ error: "photoBase64 is required" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      )
    }

    // Create Supabase client with service role for storage access
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    )

    // Decode base64 and upload photo to storage
    const binaryString = atob(photoBase64)
    const bytes = new Uint8Array(binaryString.length)
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i)
    }

    const fileName = `${crypto.randomUUID()}.jpg`
    const { error: uploadError } = await supabase.storage
      .from("chemical-photos")
      .upload(fileName, bytes, {
        contentType: "image/jpeg",
        cacheControl: "3600",
      })

    if (uploadError) {
      throw new Error(`Storage upload failed: ${uploadError.message}`)
    }

    const {
      data: { publicUrl },
    } = supabase.storage.from("chemical-photos").getPublicUrl(fileName)

    // Call Gemini API with vision + Google Search grounding
    const geminiApiKey = Deno.env.get("GEMINI_API_KEY")
    if (!geminiApiKey) {
      throw new Error("GEMINI_API_KEY not configured")
    }

    const geminiResponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${geminiApiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [
            {
              parts: [
                {
                  text: `You are analyzing a photo of an agricultural chemical product label (pesticide, herbicide, or fertilizer).

1. First, identify the product from the label image — extract the EPA registration number, product name, and manufacturer.
2. Then search the web for complete label data for this product.
3. Return the data as JSON with this exact structure:

{
  "epa_registration_number": "string or null",
  "product_name": "string or null",
  "manufacturer": "string or null",
  "signal_word": "Danger or Warning or Caution or null",
  "active_ingredients": [{"name": "string", "concentration": "string"}],
  "precautionary_statements": ["string"],
  "first_aid": {"eyes": "string", "skin": "string", "ingestion": "string", "inhalation": "string"},
  "storage_and_disposal": "string or null"
}

Return ONLY valid JSON. No markdown fences, no extra text. If you cannot identify the product, return all fields as null.`,
                },
                {
                  inline_data: {
                    mime_type: "image/jpeg",
                    data: photoBase64,
                  },
                },
              ],
            },
          ],
          tools: [{ google_search: {} }],
        }),
      }
    )

    if (!geminiResponse.ok) {
      const errText = await geminiResponse.text()
      throw new Error(`Gemini API error: ${geminiResponse.status} ${errText}`)
    }

    const geminiResult = await geminiResponse.json()

    // Extract text from Gemini response
    const responseText =
      geminiResult.candidates?.[0]?.content?.parts
        ?.filter((p: { text?: string }) => p.text)
        ?.map((p: { text: string }) => p.text)
        ?.join("") || ""

    // Parse JSON from response
    let labelData: LabelData = {
      epa_registration_number: null,
      product_name: null,
      manufacturer: null,
      signal_word: null,
      active_ingredients: null,
      precautionary_statements: null,
      first_aid: null,
      storage_and_disposal: null,
    }

    try {
      const jsonMatch = responseText.match(/\{[\s\S]*\}/)
      if (jsonMatch) {
        labelData = JSON.parse(jsonMatch[0])
      }
    } catch {
      console.error("Failed to parse Gemini response as JSON:", responseText)
    }

    const status =
      labelData.epa_registration_number || labelData.product_name
        ? "identified"
        : "unidentified"

    return new Response(
      JSON.stringify({
        photo_url: publicUrl,
        status,
        ...labelData,
        raw_extraction: geminiResult,
        latitude,
        longitude,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    )
  } catch (error) {
    console.error("analyze-label error:", error)
    return new Response(
      JSON.stringify({ error: (error as Error).message }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    )
  }
})
