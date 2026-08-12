export default async function handler(req, res) {
  // ===== RAIO-X: abra o link no navegador pra ver o diagnóstico =====
  if (req.method === 'GET') {
    const t = process.env.MP_ACCESS_TOKEN || ''
    let mp = null
    if (t) {
      const r = await fetch('https://api.mercadopago.com/users/me', {
        headers: { Authorization: 'Bearer ' + t }
      })
      mp = await r.json().catch(function () { return null })
    }
    res.json({
      tokenConfigurado: t.length > 10,
      inicioDoToken: t.slice(0, 12) + '...',
      contaMP: mp && mp.id
        ? { id: mp.id, email: mp.email, pais: mp.site_id, status: mp.status }
        : 'TOKEN INVALIDO OU AUSENTE'
    })
    return
  }

  // ===== CRIAR PAGAMENTO PIX =====
  const { valor, email, orderId } = req.body || {}

  const r = await fetch('https://api.mercadopago.com/v1/payments', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + process.env.MP_ACCESS_TOKEN,
      'Content-Type': 'application/json',
      'X-Idempotency-Key': orderId || String(Date.now())
    },
    body: JSON.stringify({
      transaction_amount: Number(valor),
      payment_method_id: 'pix',
      description: 'Compra ContaHub ' + (orderId || ''),
      payer: { email: email || 'cliente@contahub.app' },
      external_reference: orderId || String(Date.now())
    })
  })

  const d = await r.json()
  if (!d.point_of_interaction) {
    return res.status(400).json({ erro: d.message || d.error || JSON.stringify(d) })
  }

  res.json({
    id: d.id,
    qrCode: d.point_of_interaction.transaction_data.qr_code,
    qrBase64: d.point_of_interaction.transaction_data.qr_code_base64
  })
}
