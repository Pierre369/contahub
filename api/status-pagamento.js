export default async function handler(req, res) {
  if (req.method !== 'GET') {
    return res.status(405).json({ erro: 'Método não permitido' })
  }
  
  const id = req.query.id
  if (!id) {
    return res.status(400).json({ erro: 'id é obrigatório' })
  }
  
  const r = await fetch('https://api.mercadopago.com/v1/payments/' + id, {
    headers: { Authorization: 'Bearer ' + process.env.MP_ACCESS_TOKEN }
  })
  
  if (!r.ok) {
    return res.status(404).json({ erro: 'Pagamento não encontrado' })
  }
  
  const d = await r.json()
  
  res.json({ 
    id: d.id,
    status: d.status,
    status_detail: d.status_detail
  })
}
